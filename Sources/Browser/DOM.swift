import Foundation
import WebKit

// Adapted from agent-safari's MIT-licensed WeakMap snapshot design. See THIRD_PARTY_NOTICES.md.
enum DOM {
    static let world = WKContentWorld.world(name: "AgentWebKit.DOM")
    static let bootstrap = #"""
    (() => {
      if (window.__agentWebKit) return;
      const refs = new WeakMap();
      const nodes = new Map();
      let next = 1;
      // getRandomValues also works on plain HTTP; randomUUID requires a secure context.
      const epoch = Array.from(crypto.getRandomValues(new Uint8Array(6)), n=>n.toString(16).padStart(2,'0')).join('');
      function refFor(el) {
        if (!refs.has(el)) refs.set(el, `@e${next++}-${epoch}`);
        const ref = refs.get(el); nodes.set(ref, el); return ref;
      }
      function connected(el) {
        if (!el?.isConnected) return false;
        // An old frame Document may still report isConnected after its frame navigates.
        let doc=el.ownerDocument;
        while(doc!==document) {
          const frame=doc.defaultView?.frameElement;
          if(!frame || !frame.isConnected || frame.contentDocument!==doc) return false;
          doc=frame.ownerDocument;
        }
        return true;
      }
      function resolve(target) {
        let el;
        if (target.startsWith('@')) {
          el = nodes.get(target);
          if (!connected(el)) throw new Error('stale_ref: take a new snapshot');
        } else {
          const matches = query(target);
          if (matches.length !== 1) throw new Error(`selector_count: expected 1, found ${matches.length}`);
          el = matches[0];
        }
        return el;
      }
      function query(target) {
        const parts=target.split('>>>').map(p=>p.trim());
        let root=document;
        for(let i=0;i<parts.length;i++) {
          let matches;
          try { matches=root.querySelectorAll(parts[i]); }
          catch (_) { throw new Error('invalid_selector: invalid CSS selector'); }
          if(i===parts.length-1 || matches.length===0) return matches;
          if(matches.length!==1) throw new Error(`selector_count: expected 1 context, found ${matches.length}`);
          root=childRoot(matches[0]);
        }
      }
      function childRoot(el) {
        if(el.localName==='iframe' || el.localName==='frame') {
          let doc;
          try { doc=el.contentDocument; } catch (_) {}
          if(!doc) throw new Error('unsupported_context: cross-origin or unavailable frame');
          return doc;
        }
        if(el.shadowRoot) return el.shadowRoot;
        throw new Error('unsupported_context: closed or absent shadow root');
      }
      function matchesCondition(target,state,text) {
        const matches = target===null ? (document.body?[document.body]:[]) : target.startsWith('@') ? [resolve(target)] : query(target);
        if (matches.length > 1) throw new Error(`selector_count: expected 1, found ${matches.length}`);
        const el=matches[0];
        if(text!==null) return Boolean(el && visible(el) && (el.innerText||'').includes(text));
        if(state==='attached') return Boolean(el);
        if(state==='detached') return !el;
        if(state==='hidden') return !el || !visible(el);
        if(!el || !visible(el)) return false;
        const disabled=el.matches(':disabled') || el.getAttribute('aria-disabled')==='true';
        if(state==='disabled') return disabled;
        if(state==='enabled') return !disabled;
        return true;
      }
      function visible(el) {
        const r=el.getBoundingClientRect(), s=el.ownerDocument.defaultView.getComputedStyle(el);
        if (r.width<=0 || r.height<=0 || s.display==='none' || s.visibility!=='visible') return false;
        for (let node=el; node; node=node.parentElement || node.getRootNode().host || node.ownerDocument.defaultView?.frameElement) {
          const style=node.ownerDocument.defaultView.getComputedStyle(node);
          if (Number(style.opacity)===0 || style.display==='none' || style.visibility!=='visible' || node.hidden || node.inert) return false;
        }
        return true;
      }
      function snapshot() {
        for (const [ref, el] of nodes) if (!connected(el)) nodes.delete(ref);
        const elements=[];
        const unsupported=[];
        let scanned=0, truncated=false;
        function visit(root, context) {
          if(context.length>16) { truncated=true; return; }
          for(const el of root.querySelectorAll('*')) {
            if(++scanned>10000 || elements.length>=1000) { truncated=true; return; }
            const boundary=el.shadowRoot || el.localName==='iframe' || el.localName==='frame';
            if(visible(el) && (el.matches('a,button,input,select,textarea,summary,[role],[onclick],[tabindex],[contenteditable]') || boundary)) describe(el,context);
            if(boundary) {
              const child={kind:el.shadowRoot?'shadow':'frame',ref:refFor(el)};
              let nextRoot;
              try { nextRoot=childRoot(el); }
              catch(error) { unsupported.push({context:[...context,child],code:'unsupported_context',reason:String(error.message)}); continue; }
              visit(nextRoot, [...context,child]);
            }
          }
        }
        function describe(el,context) {
          const tag=el.tagName.toLowerCase(), type=el.type||'';
          const labelled=(el.getAttribute('aria-labelledby')||'').split(/\s+/).map(id=>el.getRootNode().getElementById(id)?.textContent||'').join(' ').trim();
          const name=labelled || el.getAttribute('aria-label') || Array.from(el.labels||[]).map(l=>l.innerText).join(' ') || el.getAttribute('placeholder') || el.innerText || el.getAttribute('name') || '';
          const inputRole=({checkbox:'checkbox',radio:'radio',range:'slider',number:'spinbutton',button:'button',submit:'button',reset:'button'})[type]||'textbox';
          const role=el.getAttribute('role') || ({a:'link',button:'button',textarea:'textbox',select:'combobox',input:inputRole})[tag] || tag;
          const r=el.getBoundingClientRect();
          elements.push({ref:refFor(el), context, tag, role, name:name.replace(/\s+/g,' ').trim().slice(0,200),
            value:type==='password'?'[redacted]':String(el.value||'').slice(0,200),
            disabled:Boolean(el.matches(':disabled')||el.getAttribute('aria-disabled')==='true'),
            ...(type==='checkbox'||type==='radio'?{checked:el.checked}:{}),
            ...(tag==='select'?{options:Array.from(el.options).map(o=>({value:o.value,label:o.label,selected:o.selected,disabled:o.disabled}))}:{}),
            bounds:{x:r.x,y:r.y,width:r.width,height:r.height,coordinateSpace:el.ownerDocument===document?'main-viewport':'frame-viewport'}});
        }
        visit(document,[]);
        const text=document.body?.innerText||'';
        return {elements,text:text.slice(0,20000),textScope:'main-frame',scope:'same-origin-frames-and-open-shadow-roots',limit:1000,
          unsupported,limitations:['Closed shadow roots cannot be enumerated; explicit >>> traversal returns unsupported_context.'],
          truncated:truncated||text.length>20000};
      }
      function act(kind,target,value) {
        const el=resolve(target);
        if (!visible(el) || el.matches(':disabled') || el.getAttribute('aria-disabled')==='true') throw new Error('element_not_actionable');
        el.scrollIntoView({block:'nearest'});
        if(kind==='click') el.click();
        else {
          if (el.readOnly) throw new Error('element_readonly');
          const view=el.ownerDocument.defaultView, tag=el.localName;
          if (['input','textarea','select'].includes(tag)) {
            if (tag==='input' && ['file','checkbox','radio','button','submit','reset','hidden'].includes(el.type)) throw new Error('unsupported_fill_type');
            if (tag==='select' && !Array.from(el.options).some(o=>o.value===value&&!o.disabled&&!o.parentElement.disabled)) throw new Error('invalid_option');
            const prototype=tag==='textarea'?view.HTMLTextAreaElement.prototype:tag==='select'?view.HTMLSelectElement.prototype:view.HTMLInputElement.prototype;
            Object.getOwnPropertyDescriptor(prototype,'value').set.call(el,value);
          } else if(el.isContentEditable) el.textContent=value;
          else throw new Error('element_not_editable');
          el.dispatchEvent(new view.Event('input',{bubbles:true,composed:true}));
          el.dispatchEvent(new view.Event('change',{bubbles:true,composed:true}));
        }
        return {method:'dom',nativeVerified:false,businessOutcomeVerified:false,requiresForeground:false,target};
      }
      window.__agentWebKit={snapshot,resolve,act,visible,matchesCondition};
    })();
    """#
}
