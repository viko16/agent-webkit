import Foundation

// Adapted from agent-safari's MIT-licensed WeakMap snapshot design. See THIRD_PARTY_NOTICES.md.
enum DOM {
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
      function resolve(target) {
        let el;
        if (target.startsWith('@')) {
          el = nodes.get(target);
          if (!el || !el.isConnected) throw new Error('stale_ref: take a new snapshot');
        } else {
          const matches = document.querySelectorAll(target);
          if (matches.length !== 1) throw new Error(`selector_count: expected 1, found ${matches.length}`);
          el = matches[0];
        }
        return el;
      }
      function visible(el) {
        const r=el.getBoundingClientRect(), s=getComputedStyle(el);
        return r.width>0 && r.height>0 && s.display!=='none' && s.visibility!=='hidden' && Number(s.opacity)>0;
      }
      function snapshot() {
        for (const [ref, el] of nodes) if (!el.isConnected) nodes.delete(ref);
        const candidates=document.querySelectorAll('a,button,input,select,textarea,summary,[role],[onclick],[tabindex],[contenteditable]');
        const elements=[];
        for (const el of candidates) {
          if (!visible(el)) continue;
          const tag=el.tagName.toLowerCase(), type=el.getAttribute('type')||'';
          const name=el.getAttribute('aria-label') || Array.from(el.labels||[]).map(l=>l.innerText).join(' ') || el.getAttribute('placeholder') || el.innerText || el.getAttribute('name') || '';
          const role=el.getAttribute('role') || ({a:'link',button:'button',textarea:'textbox',select:'combobox',input:type==='checkbox'?'checkbox':'textbox'})[tag] || tag;
          const r=el.getBoundingClientRect();
          elements.push({ref:refFor(el), tag, role, name:name.replace(/\s+/g,' ').trim().slice(0,200),
            value:type==='password'?'[redacted]':String(el.value||'').slice(0,200),
            disabled:Boolean(el.disabled||el.getAttribute('aria-disabled')==='true'),
            bounds:{x:r.x,y:r.y,width:r.width,height:r.height}});
          if(elements.length>=1000) break;
        }
        return {elements,text:(document.body?.innerText||'').slice(0,20000),scope:'main-frame',limit:1000};
      }
      function act(kind,target,value) {
        const el=resolve(target);
        if (!visible(el) || el.disabled || el.getAttribute('aria-disabled')==='true') throw new Error('element_not_actionable');
        el.scrollIntoView({block:'nearest'});
        if(kind==='click') el.click();
        else {
          if (el.readOnly) throw new Error('element_readonly');
          if (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement || el instanceof HTMLSelectElement) {
            if (el instanceof HTMLInputElement && ['file','checkbox','radio','button','submit','reset','hidden'].includes(el.type)) throw new Error('unsupported_fill_type');
            const prototype=el instanceof HTMLTextAreaElement?HTMLTextAreaElement.prototype:el instanceof HTMLSelectElement?HTMLSelectElement.prototype:HTMLInputElement.prototype;
            Object.getOwnPropertyDescriptor(prototype,'value').set.call(el,value);
          } else if(el.isContentEditable) el.textContent=value;
          else throw new Error('element_not_editable');
          el.dispatchEvent(new Event('input',{bubbles:true}));
          el.dispatchEvent(new Event('change',{bubbles:true}));
        }
        return {method:'dom',nativeVerified:false,requiresForeground:false,target};
      }
      window.__agentWebKit={snapshot,resolve,act,visible};
    })();
    """#
}
