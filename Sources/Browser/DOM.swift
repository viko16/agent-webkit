import Foundation
import WebKit

// Adapted from agent-safari's MIT-licensed WeakMap snapshot design. See THIRD_PARTY_NOTICES.md.
enum DOM {
    static let world = WKContentWorld.world(name: "AgentWebKit.DOM")
    static let bootstrap = #"""
    (() => {
      if (window.__agentWebKit) return;
      let refs = new WeakMap();
      let nodes = new Map();
      let next = 1;
      // getRandomValues also works on plain HTTP; randomUUID requires a secure context.
      const newEpoch = ()=>Array.from(crypto.getRandomValues(new Uint8Array(6)), n=>n.toString(16).padStart(2,'0')).join('');
      let epoch = newEpoch();
      let historyState={revision:0};
      for(const type of ['popstate','hashchange']) addEventListener(type,event=>{
        if(event.isTrusted)historyState.revision++;
      });
      addEventListener('pagehide',()=>{nodes.clear();refs=new WeakMap();next=1;epoch=newEpoch()});
      function refFor(el, snapshotNodes) {
        if (!refs.has(el)) refs.set(el, `@e${next++}-${epoch}`);
        const ref = refs.get(el); snapshotNodes.set(ref, el); return ref;
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
      function visible(el, charge=null, accessibility=false) {
        const r=el.getBoundingClientRect(), s=el.ownerDocument.defaultView.getComputedStyle(el);
        if (r.width<=0 || r.height<=0 || s.display==='none' || s.visibility!=='visible') return false;
        for (let node=el; node; node=node.parentElement || node.getRootNode().host || node.ownerDocument.defaultView?.frameElement) {
          if(charge&&!charge()) return false;
          const style=node.ownerDocument.defaultView.getComputedStyle(node);
          if (Number(style.opacity)===0 || style.display==='none' || node.hidden || node.inert ||
              (accessibility&&node.getAttribute('aria-hidden')==='true')) return false;
          // Visibility inherits within a document (including shadow trees), but
          // a hidden frame cannot be made visible by its document's descendants.
          if(node.localName==='iframe'||node.localName==='frame') {
            const bounds=node.getBoundingClientRect();
            if(style.visibility!=='visible'||bounds.width<=0||bounds.height<=0) return false;
          }
        }
        return true;
      }
      const interactiveSelector='a[href],button,input:not([type=hidden]),select,textarea,summary,[onclick],[tabindex],[contenteditable]:not([contenteditable=false]),[role~="button"],[role~="link"],[role~="checkbox"],[role~="radio"],[role~="switch"],[role~="tab"],[role~="menuitem"],[role~="combobox"],[role~="listbox"],[role~="option"],[role~="slider"],[role~="spinbutton"],[role~="textbox"]';
      function disabled(el) {
        return el.matches(':disabled') || el.getAttribute('aria-disabled')==='true';
      }
      function snapshot(scopeTarget=null, interactive=false, wantedRole=null, wantedName=null) {
        const root=scopeTarget===null?document:resolve(scopeTarget);
        // Keep strong references only for this bounded snapshot. WeakMap IDs
        // stay stable for nodes that appear again, without retaining old nodes.
        const snapshotNodes=new Map();
        const elements=[];
        const matches=[];
        const unsupported=[];
        const outputBudgetBytes=1024*1024, scanBudget=10000, encoder=new TextEncoder();
        const textStyles=new WeakMap(), blockDisplays=new Set(['block','flex','grid','list-item','table','table-row','table-cell']);
        let scanned=0, truncated=false, outputBytes=4096, exhausted=false;
        function chargeScan() {
          if(exhausted) return false;
          if(scanned>=scanBudget) { truncated=true; exhausted=true; return false; }
          scanned++;
          return true;
        }
        function scanNode(walker) {
          return chargeScan()?walker.nextNode():null;
        }
        function safePrefix(text, limit) {
          let end=Math.min(text.length,Math.max(0,limit));
          const last=text.charCodeAt(end-1);
          if(last>=0xd800&&last<=0xdbff) end--;
          return text.slice(0,end);
        }
        function bounded(value, limit=200) {
          const text=String(value||'');
          const prefix=safePrefix(text,limit);
          if(prefix.length<text.length) truncated=true;
          return prefix;
        }
        function textStyle(parent) {
          const pending=[];
          let node=parent;
          while(node&&!textStyles.has(node)) {
            if(!chargeScan()) return null;
            pending.push(node); node=node.parentElement;
          }
          let info=node?textStyles.get(node):{subtreeShown:true,block:null,excluded:false,ariaHidden:false};
          for(const element of pending.reverse()) {
            const style=element.ownerDocument.defaultView.getComputedStyle(element);
            const subtreeShown=info.subtreeShown&&style.display!=='none'&&Number(style.opacity)!==0&&!element.hidden&&!element.inert;
            info={subtreeShown,shown:subtreeShown&&style.visibility==='visible',
                  block:blockDisplays.has(style.display)?element:info.block,
                  ariaHidden:info.ariaHidden||element.getAttribute('aria-hidden')==='true',
                  excluded:info.excluded||['script','style','noscript','template'].includes(element.localName)};
            textStyles.set(element,info);
          }
          return textStyles.get(parent);
        }
        function readText(root, limit, checkVisibility=true, preserveLines=false) {
          if(!root || limit<=0 || exhausted) return '';
          // SHOW_ALL makes every nextNode step chargeable, including empty
          // elements that SHOW_TEXT can otherwise skip without a bound.
          const doc=root.ownerDocument||root, walker=doc.createTreeWalker(root,0xffffffff);
          let result='', node, previousBlock, lineBreaks=0;
          while((node=scanNode(walker))) {
            const isBreak=node.nodeType===1&&node.localName==='br';
            const alt=wantedRole!==null&&node.localName==='img'?node.getAttribute('alt'):null;
            if(node.nodeType!==3&&!isBreak&&alt===null) continue;
            const parent=isBreak||alt!==null?node:node.parentElement;
            if(!parent) continue;
            const info=textStyle(parent);
            if(!info) break;
            if(info.excluded) continue;
            if((checkVisibility||isBreak)&&!info.shown) continue;
            if(checkVisibility&&wantedRole!==null&&info.ariaHidden)continue;
            if(isBreak) { lineBreaks++; continue; }
            const raw=alt??node.data;
            let chunk=bounded(raw,limit-result.length).replace(/\s+/g,' ');
            if(!chunk) { if(raw.length) break; continue; }
            if(result&&previousBlock!==info.block) lineBreaks=Math.max(1,lineBreaks);
            if(result&&lineBreaks&&chunk.trim()) {
              result=result.replace(/ +$/,'');
              result+=safePrefix('\n'.repeat(Math.min(lineBreaks,limit)),limit-result.length);
              chunk=chunk.trimStart();
            }
            if(chunk.trim()) lineBreaks=0;
            previousBlock=info.block;
            const remaining=limit-result.length;
            result+=safePrefix(chunk,remaining);
            if(raw.length>remaining) { truncated=true; break; }
          }
          return safePrefix(result,limit).replace(preserveLines?/[^\S\n]+/g:/\s+/g,' ').trim();
        }
        function append(list,item) {
          const size=encoder.encode(JSON.stringify(item)).length+1;
          if(outputBytes+size>outputBudgetBytes) { truncated=true; exhausted=true; return; }
          list.push(item); outputBytes+=size;
        }
        function visit(root, context) {
          if(context.length>16) { truncated=true; return; }
          const walker=(root.ownerDocument||root).createTreeWalker(root,0xffffffff);
          for(let el=root.nodeType===1 && chargeScan()?root:scanNode(walker);el;el=scanNode(walker)) {
            if(el.nodeType!==1) continue;
            if(elements.length>=1000) { truncated=true; exhausted=true; return; }
            const boundary=el.shadowRoot || el.localName==='iframe' || el.localName==='frame';
            const candidate=interactive ? el.matches(interactiveSelector)&&!disabled(el)
              : boundary||el.matches('a,button,input,select,textarea,summary,[role],[onclick],[tabindex],[contenteditable]');
            if(candidate && visible(el,chargeScan,wantedRole!==null)) describe(el,context);
            if(exhausted || matches.length>1) return;
            if(boundary) {
              const child={kind:el.shadowRoot?'shadow':'frame',ref:refFor(el,snapshotNodes)};
              let nextRoot;
              try { nextRoot=childRoot(el); }
              catch(error) { append(unsupported,{context:[...context,child],code:'unsupported_context',reason:bounded(error.message)}); continue; }
              visit(nextRoot, [...context,child]);
            }
          }
        }
        function describe(el,context) {
          const tag=bounded(el.tagName.toLowerCase()), type=el.type||'';
          const inputRole=({checkbox:'checkbox',radio:'radio',range:'slider',number:'spinbutton',button:'button',submit:'button',reset:'button',search:'searchbox'})[type]||'textbox';
          const role=bounded(el.getAttribute('role')).trim().split(/\s+/)[0]
            || ({a:el.hasAttribute('href')?'link':'generic',button:'button',summary:'button',textarea:'textbox',
                 select:el.multiple||el.size>1?'listbox':'combobox',input:inputRole})[tag] || tag;
          if(wantedRole!==null && role!==wantedRole)return;
          const ids=bounded(el.getAttribute('aria-labelledby'),2048).split(/\s+/);
          let labelled='', labels='';
          if(ids.length>16) truncated=true;
          for(const id of ids.slice(0,16)) {
            if(labelled.length>=200) { truncated=true; break; }
            const label=el.getRootNode().getElementById(id);
            const style=wantedRole!==null&&label?textStyle(label):null;
            const visibleLabel=Boolean(style?.shown&&!style.ariaHidden);
            const text=readText(label,200-labelled.length,visibleLabel);
            if(text) labelled+=(labelled?' ':'')+text;
          }
          if(el.labels?.length>16) truncated=true;
          for(let i=0;i<Math.min(el.labels?.length||0,16);i++) {
            if(labels.length>=200) { truncated=true; break; }
            labels+=(labels?' ':'')+readText(el.labels[i],200-labels.length);
          }
          const name=(labelled || bounded(el.getAttribute('aria-label')) || labels || bounded(el.getAttribute('placeholder'))
            || (tag==='input'&&['button','submit','reset'].includes(type)?bounded(el.value):'')
            || readText(el,200) || bounded(el.getAttribute('alt')) || bounded(el.getAttribute('title'))
            || (wantedRole===null?bounded(el.getAttribute('name')):'')).replace(/\s+/g,' ').trim();
          if(wantedRole!==null) {
            if(name===wantedName) matches.push({el,context,tag,type,role,name});
            return;
          }
          appendElement({el,context,tag,type,role,name});
        }
        function appendElement({el,context,tag,type,role,name}) {
          const options=[];
          let value=type==='password'?'[redacted]':tag==='select'?'':bounded(el.value);
          if(tag==='select') {
            if(el.options.length>100) truncated=true;
            for(let i=0;i<Math.min(el.options.length,100);i++) {
              const option=el.options[i];
              const text=readText(option,200,false), rawValue=option.getAttribute('value'), rawLabel=option.getAttribute('label');
              options.push({value:rawValue===null?text:bounded(rawValue),label:rawLabel===null?text:bounded(rawLabel),selected:option.selected,disabled:option.disabled});
            }
            const selected=el.options[el.selectedIndex];
            if(selected) {
              const rawValue=selected.getAttribute('value');
              value=rawValue===null?readText(selected,200,false):bounded(rawValue);
            }
          }
          const r=el.getBoundingClientRect();
          append(elements,{ref:refFor(el,snapshotNodes), context, tag, role, name:bounded(name),
            value,
            disabled:disabled(el),
            readOnly:Boolean(el.readOnly||el.getAttribute('aria-readonly')==='true'),
            ...(type==='checkbox'||type==='radio'?{checked:el.checked}:{}),
            ...(tag==='select'?{options}:{}),
            bounds:{x:r.x,y:r.y,width:r.width,height:r.height,coordinateSpace:el.ownerDocument===document?'main-viewport':'frame-viewport'}});
        }
        visit(root,[]);
        if(wantedRole!==null) {
          if(matches.length>1) throw new Error('selector_count: role and name matched multiple elements');
          if(truncated) throw new Error('snapshot_truncated: cannot confirm a unique role/name; narrow --scope');
          if(matches.length!==1) throw new Error('selector_count: role and name matched no elements');
          appendElement(matches[0]);
        }
        const bodyText=interactive||wantedRole!==null?'':readText(root===document?document.body:root,20000,true,true);
        const text=outputBytes+encoder.encode(JSON.stringify(bodyText)).length<=outputBudgetBytes?bodyText:'';
        if(text!==bodyText) truncated=true;
        const exposedRefs=new Set(elements.map(element=>element.ref));
        for(const item of [...elements,...unsupported]) for(const step of item.context) exposedRefs.add(step.ref);
        for(const ref of snapshotNodes.keys()) if(!exposedRefs.has(ref)) snapshotNodes.delete(ref);
        nodes=snapshotNodes;
        return {elements,text,textScope:interactive||wantedRole!==null?'omitted':root===document?'main-frame':'selected-subtree',
          scope:'same-origin-frames-and-open-shadow-roots',scopeTarget,interactive,role:wantedRole,name:wantedName,
          limit:1000,outputBudgetBytes,scanBudget,scannedNodes:scanned,
          unsupported,limitations:['Closed shadow roots cannot be enumerated; explicit >>> traversal returns unsupported_context.'],
          truncated};
      }
      function clickablePoint(el) {
        function containsHit(node,x,y) {
          let hit=node.ownerDocument.elementFromPoint(x,y);
          while(hit?.shadowRoot) {
            const inner=hit.shadowRoot.elementFromPoint(x,y);
            if(!inner || inner.getRootNode()!==hit.shadowRoot) break;
            hit=inner;
          }
          for(let candidate=hit;candidate;candidate=candidate.assignedSlot||candidate.parentElement||candidate.getRootNode().host) {
            if(candidate===node)return true;
          }
          return false;
        }
        function checkPoint(x,y) {
          let node=el, documentLocal=false;
          for(;;) {
            if(!containsHit(node,x,y))return null;
            const view=node.ownerDocument.defaultView;
            if(view===view.top)break;
            const frame=view.frameElement;
            if(!frame) { documentLocal=true; break; }
            for(let parent=frame;parent;parent=parent.parentElement||parent.getRootNode().host) {
              const style=parent.ownerDocument.defaultView.getComputedStyle(parent);
              if(style.transform!=='none'||style.translate!=='none'||style.rotate!=='none'||style.scale!=='none'
                 ||style.perspective!=='none'||![undefined,'normal','1'].includes(style.zoom)) {
                throw new Error('element_not_actionable: transformed frame geometry cannot be checked');
              }
            }
            if(x<0||y<0||x>=frame.clientWidth||y>=frame.clientHeight)return null;
            const box=frame.getBoundingClientRect();
            x+=box.x+frame.clientLeft; y+=box.y+frame.clientTop; node=frame;
          }
          return documentLocal?'document-local':'through-same-origin-ancestors';
        }
        const view=el.ownerDocument.defaultView, rects=el.getClientRects();
        for(let i=0;i<Math.min(rects.length,8);i++) {
          const box=rects[i], left=Math.max(0,box.left), top=Math.max(0,box.top);
          const width=Math.min(view.innerWidth,box.right)-left, height=Math.min(view.innerHeight,box.bottom)-top;
          if(width<=0||height<=0)continue;
          for(const [x,y] of [[.5,.5],[.2,.2],[.8,.2],[.2,.8],[.8,.8]]) {
            const scope=checkPoint(left+width*x,top+height*y);
            if(scope)return scope;
          }
        }
        throw new Error('element_not_actionable: no unobscured point sampled after scrolling');
      }
      function act(kind,target,value) {
        const el=resolve(target);
        const view=el.ownerDocument.defaultView, tag=el.localName;
        const toggle=kind==='check'||kind==='uncheck', desired=kind==='check';
        const select=kind==='select';
        const result={method:'dom',nativeVerified:false,physicalInput:false,userActivationVerified:false,
          businessOutcomeVerified:false,requiresForeground:false,target};
        if(toggle) {
          if(tag!=='input'||el.type!=='checkbox')throw new Error('unsupported_checkbox_target: target must be a native checkbox');
          if(el.checked===desired && !el.indeterminate)return {...result,checked:desired,changed:false};
          if(el.checked===desired)throw new Error('element_not_actionable: checkbox is indeterminate');
        }
        if(select && (tag!=='select'||el.multiple))throw new Error('invalid_option: select requires a native single-select');
        if (!visible(el) || disabled(el)) throw new Error('element_not_actionable');
        el.scrollIntoView({block:'nearest',inline:'nearest',behavior:'instant'});
        if(kind==='click'||toggle) {
          if(!connected(el)||!visible(el)||disabled(el))throw new Error('element_not_actionable: target changed during scroll');
          result.hitTest={scope:clickablePoint(el),method:'sampled-dom-points'};
          if(typeof el.click==='function') el.click();
          else el.dispatchEvent(new view.MouseEvent('click',{bubbles:true,cancelable:true,composed:true,view}));
          if(toggle) {
            if(!connected(el)||el.checked!==desired||el.indeterminate)
              throw new Error('dom_state_mismatch: checkbox did not retain the requested state after click');
            return {...result,checked:desired,changed:true};
          }
        }
        else {
          if (el.readOnly || el.getAttribute('aria-readonly')==='true') throw new Error('element_readonly');
          let optionIndex=-1;
          const enabledOption=option=>option?.value===value&&!option.disabled&&!option.parentElement.disabled;
          if (['input','textarea','select'].includes(tag)) {
            if (tag==='input' && ['file','checkbox','radio','button','submit','reset','hidden'].includes(el.type)) throw new Error('unsupported_fill_type');
            if (tag==='select') {
              optionIndex=Array.from(el.options).findIndex(enabledOption);
              if(optionIndex<0)throw new Error('invalid_option');
              if(select && enabledOption(el.options[el.selectedIndex])) {
                return {...result,selectedValue:value,changed:false,events:[]};
              }
            }
            const prototype=tag==='textarea'?view.HTMLTextAreaElement.prototype:tag==='select'?view.HTMLSelectElement.prototype:view.HTMLInputElement.prototype;
            if(select) Object.getOwnPropertyDescriptor(prototype,'selectedIndex').set.call(el,optionIndex);
            else Object.getOwnPropertyDescriptor(prototype,'value').set.call(el,value);
          } else if(el.isContentEditable) el.textContent=value;
          else throw new Error('element_not_editable');
          const input=tag==='select' ? new view.Event('input',{bubbles:true,composed:true}) :
            new view.InputEvent('input',{bubbles:true,composed:true,inputType:'insertReplacementText',data:value});
          el.dispatchEvent(input);
          el.dispatchEvent(new view.Event('change',{bubbles:true,composed:true}));
          if(select) {
            if(!connected(el)||!enabledOption(el.options[el.selectedIndex]))
              throw new Error('dom_state_mismatch: select did not retain the requested value after change');
            return {...result,selectedValue:value,changed:true,events:['input','change']};
          }
        }
        return result;
      }
      function scroll(x,y) {
        const before={x:scrollX,y:scrollY};
        window.scrollBy({left:x,top:y,behavior:'instant'});
        return {method:'dom-scroll',before,after:{x:scrollX,y:scrollY},coordinateSpace:'document-css',businessOutcomeVerified:false};
      }
      function inputState(expectedEpoch=null,target=null) {
        if(expectedEpoch!==null&&expectedEpoch!==epoch) throw new Error('input_target_changed: document changed; input may already have taken effect');
        let el=document.activeElement;
        while(el?.shadowRoot?.activeElement) el=el.shadowRoot.activeElement;
        if(el?.localName==='iframe'||el?.localName==='frame') throw new Error('unsupported_context: native input is limited to the main document');
        if(target!==null&&resolve(target)!==el) throw new Error('input_focus_failed: target lost DOM focus');
        const tabIndex=el?.getAttribute('tabindex');
        const acceptsKeys=el&&(el!==document.body&&el!==document.documentElement||el.isContentEditable||typeof tabIndex==='string'&&/^[+-]?\d+$/.test(tabIndex.trim()));
        return {epoch,tag:el?.localName||'',documentHasFocus:document.hasFocus(),
          actionable:Boolean(acceptsKeys&&visible(el)&&!el.matches(':disabled')&&el.getAttribute('aria-disabled')!=='true'&&!el.inert)};
      }
      function focus(target) {
        const el=resolve(target);
        if(el.ownerDocument!==document||['iframe','frame'].includes(el.localName)) throw new Error('unsupported_context: focus is limited to the main document and its open shadow roots');
        if(!visible(el)||el.matches(':disabled')||el.getAttribute('aria-disabled')==='true') throw new Error('element_not_actionable');
        el.focus({preventScroll:true});
        let active=document.activeElement;
        while(active?.shadowRoot?.activeElement) active=active.shadowRoot.activeElement;
        const state=inputState();
        if(active!==el||!state.actionable) throw new Error('input_focus_failed: element did not accept actionable DOM focus');
        return state;
      }
      let screenshotState=null;
      function prepareScreenshot(target) {
        const el=resolve(target);
        if(!visible(el)) throw new Error('element_not_actionable: invisible or zero-sized screenshot target');
        const positions=[], views=new Set();
        for(let node=el;node;node=node.parentElement||node.getRootNode().host||node.ownerDocument.defaultView?.frameElement) {
          if(typeof node.scrollTo==='function') positions.push({node,left:node.scrollLeft,top:node.scrollTop});
          views.add(node.ownerDocument.defaultView);
        }
        const token=crypto.getRandomValues(new Uint32Array(4)).join('-');
        screenshotState={token,el,positions,views:Array.from(views,view=>({view,left:view.scrollX,top:view.scrollY}))};
        el.scrollIntoView({block:'center',inline:'center',behavior:'instant'});
        return token;
      }
      function screenshotBounds(token) {
        if(screenshotState?.token!==token||!connected(screenshotState.el)) throw new Error('stale_ref: screenshot document changed');
        const el=screenshotState.el;
        if(!visible(el)) throw new Error('element_not_actionable: screenshot target became invisible');
        const original=el.getBoundingClientRect();
        let rect={x:original.x,y:original.y,width:original.width,height:original.height},clipped=false;
        function intersect(x,y,width,height,clipX=true,clipY=true) {
          const left=clipX?Math.max(rect.x,x):rect.x, top=clipY?Math.max(rect.y,y):rect.y;
          const right=clipX?Math.min(rect.x+rect.width,x+width):rect.x+rect.width;
          const bottom=clipY?Math.min(rect.y+rect.height,y+height):rect.y+rect.height;
          clipped ||= left!==rect.x||top!==rect.y||right!==rect.x+rect.width||bottom!==rect.y+rect.height;
          rect={x:left,y:top,width:right-left,height:bottom-top};
        }
        let node=el;
        function requireUntransformedAncestors(start) {
          for(let parent=start;parent;parent=parent.parentElement||parent.getRootNode().host) {
            const style=parent.ownerDocument.defaultView.getComputedStyle(parent);
            if(style.transform!=='none'||![undefined,'normal','1'].includes(style.zoom)) throw new Error('unsupported_screenshot_geometry: transformed clipping or iframe ancestor');
          }
        }
        while(node) {
          const view=node.ownerDocument.defaultView;
          for(let parent=node.parentElement||node.getRootNode().host;parent;parent=parent.parentElement||parent.getRootNode().host) {
            const style=view.getComputedStyle(parent), box=parent.getBoundingClientRect();
            const clipX=['hidden','clip','auto','scroll'].includes(style.overflowX),clipY=['hidden','clip','auto','scroll'].includes(style.overflowY);
            if(clipX||clipY) {
              requireUntransformedAncestors(parent);
              intersect(box.x+parent.clientLeft,box.y+parent.clientTop,parent.clientWidth,parent.clientHeight,clipX,clipY);
            }
          }
          intersect(0,0,view.innerWidth,view.innerHeight);
          if(view===window) break;
          const frame=view.frameElement;
          if(!frame) throw new Error('unsupported_context: inaccessible screenshot frame');
          requireUntransformedAncestors(frame);
          const box=frame.getBoundingClientRect();
          intersect(0,0,frame.clientWidth,frame.clientHeight);
          rect.x+=box.x+frame.clientLeft;rect.y+=box.y+frame.clientTop;
          node=frame;
        }
        if(![rect.x,rect.y,rect.width,rect.height].every(Number.isFinite)||rect.width<=0||rect.height<=0) throw new Error('element_not_actionable: screenshot target is fully clipped');
        return {...rect,clipped,viewportWidth:innerWidth,viewportHeight:innerHeight};
      }
      function restoreScreenshot(token) {
        if(screenshotState?.token!==token) return false;
        const state=screenshotState;screenshotState=null;
        for(const entry of state.positions) entry.node.scrollTo({left:entry.left,top:entry.top,behavior:'instant'});
        for(const entry of state.views) entry.view.scrollTo({left:entry.left,top:entry.top,behavior:'instant'});
        return state.positions.every(e=>Math.abs(e.node.scrollLeft-e.left)<1&&Math.abs(e.node.scrollTop-e.top)<1)&&
          state.views.every(e=>Math.abs(e.view.scrollX-e.left)<1&&Math.abs(e.view.scrollY-e.top)<1);
      }
      function pageScreenshotBounds(token) {
        if(screenshotState?.token!==token||!connected(screenshotState.el)) throw new Error('stale_ref: screenshot document changed');
        return {width:Math.max(document.documentElement.scrollWidth,document.body?.scrollWidth||0,innerWidth),
          height:Math.max(document.documentElement.scrollHeight,document.body?.scrollHeight||0,innerHeight),
          viewportWidth:innerWidth,viewportHeight:innerHeight,x:scrollX,y:scrollY};
      }
      function scrollScreenshot(token,y) {
        pageScreenshotBounds(token);
        window.scrollTo({left:0,top:y,behavior:'instant'});
        return pageScreenshotBounds(token);
      }
      window.__agentWebKit={snapshot,resolve,act,scroll,historyState,focus,inputState,visible,matchesCondition,prepareScreenshot,screenshotBounds,restoreScreenshot,pageScreenshotBounds,scrollScreenshot};
    })();
    """#
}
