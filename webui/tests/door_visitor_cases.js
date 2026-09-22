"use strict";
async function runDoorVisitorChecks(phase) {
  const results=[],frames=document.getElementById('frames');
  const assert=(value,message)=>{if(!value)throw Error(message);};
  const wait=async(predicate,message,timeout=4000)=>{const end=Date.now()+timeout;while(Date.now()<end){if(predicate())return;await new Promise(resolve=>setTimeout(resolve,25));}throw Error(message);};
  const inside=(r,w,h)=>r.width>=44&&r.height>=44&&r.left>=-1&&r.top>=-1&&r.right<=w+1&&r.bottom<=h+1;
  const overlap=(a,b)=>a.left<b.right&&a.right>b.left&&a.top<b.bottom&&a.bottom>b.top;
  async function open(profile,options={}) {
    frames.innerHTML='';const frame=document.createElement('iframe');frame.style.cssText=`border:0;width:${profile[0]}px;height:${profile[1]}px;`;
    frame.src='/door.html?'+new URLSearchParams(Object.assign({phase,flow:'purpose_first',lang:'en'},options));frames.appendChild(frame);
    await new Promise(resolve=>frame.onload=resolve);const win=frame.contentWindow,doc=win.document;
    await wait(()=>doc.querySelector('[data-door]'),'Door button not rendered');
    return {win,doc,f:win.doorVisitorFixture,$:id=>doc.getElementById(id),requests:url=>win.doorVisitorFixture.requests.filter(r=>r.url===url)};
  }
  async function test(id,body){const only=new URLSearchParams(location.search).get('case');if(only&&!id.includes(only))return;try{const detail=await body();results.push({id,status:'PASS',detail});}catch(error){results.push({id,status:'FAIL',message:error.message});}}
  await test('Purpose-first waits for a choice and sends the chosen purpose with the call',async()=>{
    const p=await open([768,1024]);p.doc.querySelector('[data-door]').click();assert(p.requests('/api/panel/press').length===0,'Rang before selecting a purpose');
    p.doc.querySelector('[data-purpose="delivery"]').click();await wait(()=>!p.$('cancelCall').disabled,'Call identity not accepted');
    const sent=new URLSearchParams(p.requests('/api/panel/press')[0].body);assert(sent.get('purpose')==='delivery','Selected purpose missing');
    p.$('cancelCall').click();await wait(()=>p.requests('/api/panel/cancel').length===1,'Cancel not sent');
    assert(new URLSearchParams(p.requests('/api/panel/cancel')[0].body).get('call_id')===p.f.state.doors[0].call_id,'Cancel used another call identity');
  });
  await test('Purpose-first Back survives background snapshots and never rings',async()=>{
    const p=await open([320,480]);p.doc.querySelector('[data-door]').click();
    const before=p.requests('/api/panel/state').length;await wait(()=>p.requests('/api/panel/state').length>before,'Background snapshot missing');
    await new Promise(resolve=>setTimeout(resolve,30));assert(!p.$('cancelCall').disabled,'Idle snapshot disabled preflight Back');
    p.$('cancelCall').click();assert(p.requests('/api/panel/press').length===0&&p.requests('/api/panel/cancel').length===0,'Back created or cancelled a call');
    assert(p.$('callingView').style.display==='none','Back did not return home');
  });
  await test('Ring-then-purpose starts once and Skip does not cancel',async()=>{
    const p=await open([768,1024],{flow:'ring_then_purpose'});p.doc.querySelector('[data-door]').click();
    await wait(()=>p.doc.querySelector('[data-purpose=""]')&&!p.$('cancelCall').disabled,'Post-ring purpose controls missing');
    assert(p.requests('/api/panel/press').length===1,'Wrong initial call count');
    p.doc.querySelector('[data-purpose=""]').click();assert(p.requests('/api/panel/cancel').length===0&&p.requests('/api/panel/purpose').length===0,'Skip issued a cancel or purpose mutation');
    p.$('cancelCall').click();await wait(()=>p.requests('/api/panel/cancel').length===1,'Explicit cancel missing');
  });
  await test('Answered state retires purpose actions and the stable action ends only the call',async()=>{
    const p=await open([768,1024],{flow:'ring_then_purpose'});p.doc.querySelector('[data-door]').click();
    await wait(()=>p.doc.querySelector('[data-purpose="delivery"]')&&!p.$('cancelCall').disabled,'Purpose control missing');
    const late=p.doc.querySelector('[data-purpose="delivery"]');p.f.setCall('in_call');
    await wait(()=>p.$('cancelCall').getAttribute('data-semantic-id')==='call.end','Answered state not rendered');
    assert(p.$('callingMsg').textContent==='In call','Answered title still says Calling');
    assert(p.$('purposeStep').style.display==='none','Answered call retains purpose choices');late.onclick();
    assert(p.requests('/api/panel/purpose').length===0,'Late purpose callback changed an answered call');
    p.$('cancelCall').click();await wait(()=>p.requests('/api/panel/hangup').length===1,'End did not use hangup');
    assert(p.requests('/api/panel/cancel').length===0,'Answered action used visitor cancel');
  });
  for(const input of ['mouse','pointer','touch','keyboard']) {
    await test(`Held ${input} Cancel cannot turn into End when the call connects`,async()=>{
      const p=await open([320,480],{flow:'ring_then_purpose'});p.doc.querySelector('[data-door]').click();
      await wait(()=>!p.$('cancelCall').disabled,'Call not accepted');const button=p.$('cancelCall');
      const start=input==='keyboard'?'keydown':input==='touch'?'touchstart':input==='pointer'?'pointerdown':'mousedown';
      const event=()=>input==='keyboard'?new p.win.KeyboardEvent('keydown',{key:' ',keyCode:32,bubbles:true}):new p.win.Event(start,{bubbles:true});
      button.dispatchEvent(event());p.f.setCall('in_call');
      await wait(()=>button.getAttribute('data-semantic-id')==='call.end','Connected state not rendered');
      if(input==='keyboard')button.dispatchEvent(new p.win.KeyboardEvent('keydown',{key:' ',keyCode:32,repeat:true,bubbles:true}));
      button.dispatchEvent(input==='keyboard'?new p.win.KeyboardEvent('keyup',{key:' ',keyCode:32,bubbles:true}):new p.win.Event(input==='touch'?'touchend':input==='pointer'?'pointerup':'mouseup',{bubbles:true}));
      button.dispatchEvent(new p.win.MouseEvent('click',{detail:input==='keyboard'?0:1,bubbles:true}));
      assert(p.requests('/api/panel/hangup').length===0&&p.requests('/api/panel/cancel').length===0,'Held Cancel was reinterpreted after connecting');
      button.dispatchEvent(event());
      button.dispatchEvent(input==='keyboard'?new p.win.KeyboardEvent('keyup',{key:' ',keyCode:32,bubbles:true}):new p.win.Event(input==='touch'?'touchend':input==='pointer'?'pointerup':'mouseup',{bubbles:true}));
      button.dispatchEvent(new p.win.MouseEvent('click',{detail:input==='keyboard'?0:1,bubbles:true}));
      await wait(()=>p.requests('/api/panel/hangup').length===1,'Fresh same-input End activation rejected');
    });
  }
  await test('Held Back cannot cancel the call started by a purpose choice',async()=>{
    const p=await open([320,480]);p.doc.querySelector('[data-door]').click();const button=p.$('cancelCall');
    button.dispatchEvent(new p.win.MouseEvent('mousedown',{bubbles:true}));p.doc.querySelector('[data-purpose="delivery"]').click();
    await wait(()=>!button.disabled,'Call not accepted');button.dispatchEvent(new p.win.MouseEvent('mouseup',{bubbles:true}));
    button.dispatchEvent(new p.win.MouseEvent('click',{detail:1,bubbles:true}));
    assert(p.requests('/api/panel/cancel').length===0&&p.$('callingView').style.display!=='none','Held Back cancelled or hid a later call');
  });
  await test('Cancelled and outside gestures cannot mutate a call and fresh gestures still work',async()=>{
    const p=await open([320,480],{flow:'ring_then_purpose'});p.doc.querySelector('[data-door]').click();
    await wait(()=>!p.$('cancelCall').disabled,'Call not accepted');const button=p.$('cancelCall');
    for(const cancelled of ['pointercancel','touchcancel','mouseleave','blur']) {
      button.dispatchEvent(new p.win.Event(cancelled==='touchcancel'?'touchstart':cancelled==='pointercancel'?'pointerdown':'mousedown',{bubbles:true}));
      button.dispatchEvent(new p.win.Event(cancelled,{bubbles:true}));
      button.dispatchEvent(new p.win.MouseEvent('click',{detail:1,bubbles:true}));
    }
    button.dispatchEvent(new p.win.MouseEvent('mousedown',{bubbles:true}));p.doc.body.dispatchEvent(new p.win.MouseEvent('mouseup',{bubbles:true}));
    button.dispatchEvent(new p.win.MouseEvent('click',{detail:1,bubbles:true}));
    assert(p.requests('/api/panel/cancel').length===0,'Cancelled or outside gesture mutated the call');
    button.dispatchEvent(new p.win.MouseEvent('mousedown',{bubbles:true}));button.dispatchEvent(new p.win.MouseEvent('mouseup',{bubbles:true}));
    button.dispatchEvent(new p.win.MouseEvent('click',{detail:1,bubbles:true}));await wait(()=>p.requests('/api/panel/cancel').length===1,'Fresh Cancel rejected');
  });
  await test('A gesture from an ended call cannot apply to a replacement call',async()=>{
    const p=await open([320,480],{flow:'ring_then_purpose'});p.doc.querySelector('[data-door]').click();
    await wait(()=>!p.$('cancelCall').disabled,'Call not accepted');const button=p.$('cancelCall'),oldId=p.f.state.doors[0].call_id;
    button.dispatchEvent(new p.win.MouseEvent('mousedown',{bubbles:true}));p.f.setCall('expired');
    await wait(()=>p.$('callingView').style.display==='none','Terminal call did not retire',6000);
    p.doc.querySelector('[data-door]').click();await wait(()=>!button.disabled,'Replacement call not accepted');
    assert(p.f.state.doors[0].call_id!==oldId,'Fixture did not replace identity');
    button.dispatchEvent(new p.win.MouseEvent('mouseup',{bubbles:true}));button.dispatchEvent(new p.win.MouseEvent('click',{detail:1,bubbles:true}));
    assert(p.requests('/api/panel/cancel').length===0,'Old gesture cancelled replacement call');
  });
  for(const input of ['outside mouse','cancelled touch','cancelled pointer']) {
    await test(`Gesture retirement: ${input} allows the next call first assistive activation`,async()=>{
      const p=await open([320,480],{flow:'ring_then_purpose'});p.doc.querySelector('[data-door]').click();
      await wait(()=>!p.$('cancelCall').disabled,'Call not accepted');const button=p.$('cancelCall');
      button.dispatchEvent(new p.win.Event(input==='cancelled touch'?'touchstart':input==='cancelled pointer'?'pointerdown':'mousedown',{bubbles:true}));
      if(input==='outside mouse')p.doc.body.dispatchEvent(new p.win.MouseEvent('mouseup',{bubbles:true}));
      else button.dispatchEvent(new p.win.Event(input==='cancelled touch'?'touchcancel':'pointercancel',{bubbles:true}));
      p.f.setCall('expired');await wait(()=>p.$('callingView').style.display==='none','Terminal call did not retire',6000);
      p.doc.querySelector('[data-door]').click();await wait(()=>!button.disabled,'Replacement call not accepted');
      button.dispatchEvent(new p.win.MouseEvent('click',{detail:0,bubbles:true}));
      await wait(()=>p.requests('/api/panel/cancel').length===1,'First new-call assistive activation was swallowed');
    });
  }
  await test('Gesture retirement: cancelled keyboard release cannot become a new End action',async()=>{
    const p=await open([320,480],{flow:'ring_then_purpose'});p.doc.querySelector('[data-door]').click();
    await wait(()=>!p.$('cancelCall').disabled,'Call not accepted');const button=p.$('cancelCall');
    button.dispatchEvent(new p.win.KeyboardEvent('keydown',{key:' ',keyCode:32,bubbles:true}));
    button.dispatchEvent(new p.win.KeyboardEvent('keydown',{key:'Escape',keyCode:27,bubbles:true}));
    p.f.setCall('in_call');await wait(()=>button.getAttribute('data-semantic-id')==='call.end','Connected state not rendered');
    const release=new p.win.KeyboardEvent('keyup',{key:' ',keyCode:32,bubbles:true,cancelable:true});button.dispatchEvent(release);
    button.dispatchEvent(new p.win.MouseEvent('click',{detail:0,bubbles:true}));
    assert(p.requests('/api/panel/hangup').length===0,'Cancelled keyboard release became End');
    assert(release.defaultPrevented,'Cancelled key release retained browser default activation');
    await new Promise(resolve=>setTimeout(resolve,25));button.dispatchEvent(new p.win.MouseEvent('click',{detail:0,bubbles:true}));
    await wait(()=>p.requests('/api/panel/hangup').length===1,'Later assistive End activation was swallowed');
  });
  for(const input of ['mouse','pointer','touch','keyboard']) {
    await test(`Release without click: disabled ${input} action does not swallow the next call first AT activation`,async()=>{
      const p=await open([320,480],{flow:'ring_then_purpose'});p.doc.querySelector('[data-door]').click();
      await wait(()=>!p.$('cancelCall').disabled,'Call not accepted');const button=p.$('cancelCall');
      button.dispatchEvent(input==='keyboard'?new p.win.KeyboardEvent('keydown',{key:' ',keyCode:32,bubbles:true}):new p.win.Event(input==='mouse'?'mousedown':input==='pointer'?'pointerdown':'touchstart',{bubbles:true}));
      p.f.setCall('expired');await wait(()=>button.disabled,'Terminal action was not disabled');
      button.dispatchEvent(input==='keyboard'?new p.win.KeyboardEvent('keyup',{key:' ',keyCode:32,bubbles:true,cancelable:true}):new p.win.Event(input==='mouse'?'mouseup':input==='pointer'?'pointerup':'touchend',{bubbles:true}));
      await wait(()=>p.$('callingView').style.display==='none','Terminal call did not retire',6000);
      p.doc.querySelector('[data-door]').click();await wait(()=>!button.disabled,'Replacement call not accepted');
      button.dispatchEvent(new p.win.MouseEvent('click',{detail:0,bubbles:true}));
      await wait(()=>p.requests('/api/panel/cancel').length===1,'Released old gesture swallowed first new-call AT activation');
    });
  }
  await test('Release without click: held old keyboard release cannot activate a replacement call',async()=>{
    const p=await open([320,480],{flow:'ring_then_purpose'});p.doc.querySelector('[data-door]').click();
    await wait(()=>!p.$('cancelCall').disabled,'Call not accepted');const button=p.$('cancelCall');
    button.dispatchEvent(new p.win.KeyboardEvent('keydown',{key:' ',keyCode:32,bubbles:true}));
    p.f.setCall('expired');await wait(()=>p.$('callingView').style.display==='none','Terminal call did not retire',6000);
    p.doc.querySelector('[data-door]').click();await wait(()=>!button.disabled,'Replacement call not accepted');
    const release=new p.win.KeyboardEvent('keyup',{key:' ',keyCode:32,bubbles:true,cancelable:true});button.dispatchEvent(release);
    button.dispatchEvent(new p.win.MouseEvent('click',{detail:0,bubbles:true}));
    assert(p.requests('/api/panel/cancel').length===0,'Held old keyboard release cancelled replacement call');
    assert(release.defaultPrevented,'Retired keyboard gesture retained default activation');
    await new Promise(resolve=>setTimeout(resolve,25));button.dispatchEvent(new p.win.MouseEvent('click',{detail:0,bubbles:true}));
    await wait(()=>p.requests('/api/panel/cancel').length===1,'Later new-call AT activation rejected');
  });
  for(const profile of [[320,480],[844,390],[768,1024],[1024,768]])for(const lang of ['en','zh'])for(const large of ['0','1']){
    await test(`Layout ${profile.join('x')} ${lang} semantic font ${large==='1'?'150%':'100%'}`,async()=>{
      const p=await open(profile,{lang,large,long:'1'}),primary=p.doc.querySelector('[data-door]');
      const main=p.$('main').getBoundingClientRect(),primaryRect=primary.getBoundingClientRect();
      assert(inside(primaryRect,...profile)&&primaryRect.bottom<=main.bottom+1,'Primary call is clipped or below minimum touch size');
      primary.click();const before=p.$('cancelCall').getBoundingClientRect(),sos=p.doc.querySelector('.dbSosTrigger').getBoundingClientRect();
      assert(inside(before,...profile),'Back/cancel is clipped during purpose choice');assert(!overlap(before,sos),'Call action overlaps SOS');
      p.doc.querySelector('[data-purpose="delivery"]').click();await wait(()=>!p.$('cancelCall').disabled,'Call response missing');
      const ringing=p.$('cancelCall').getBoundingClientRect();p.f.setCall('in_call');
      await wait(()=>p.$('cancelCall').getAttribute('data-semantic-id')==='call.end','Connected state missing');
      const connected=p.$('cancelCall').getBoundingClientRect();
      assert(inside(connected,...profile),'End call is clipped');assert(Math.abs(ringing.bottom-connected.bottom)<1&&Math.abs(ringing.left-connected.left)<1,'Action moved when call connected');
      assert(!p.doc.querySelector('[data-semantic-id="unlock.command"]'),'Visitor action became unlock');
      return {viewport:profile,language:lang,font_scale:large==='1'?1.5:1,action:{left:connected.left,top:connected.top,right:connected.right,bottom:connected.bottom}};
    });
  }
  await test('Ordinary offline status is neutral while the existing SOS overlay stays separate',async()=>{
    const p=await open([320,480]);p.f.down=true;
    await wait(()=>p.win.getComputedStyle(p.$('offlineBand')).display!=='none','Offline state not visible',12000);
    assert(p.win.getComputedStyle(p.$('offlineBand')).backgroundColor==='rgb(38, 49, 60)','Ordinary outage still uses a red alarm background');
    assert(p.win.getComputedStyle(p.doc.querySelector('.dbEmergencyOverlay')).display==='none','Ordinary outage opened the SOS overlay');
    p.f.down=false;p.f.state.emergency={active:true};
    await wait(()=>p.win.getComputedStyle(p.doc.querySelector('.dbEmergencyOverlay')).display!=='none','Replicated SOS not visible');
    assert(p.doc.querySelector('.dbEmergencyOverlay').getAttribute('role')==='alert','SOS lost alert semantics');
    assert(!p.doc.querySelector('.dbEmergencyOverlay button'),'Visitor acquired an alarm-clear action');
  });
  await test('Keyboard cancellation and assistive activation retain the existing SOS operation path',async()=>{
    const p=await open([320,480]),trigger=p.doc.querySelector('.dbSosTrigger');
    trigger.dispatchEvent(new p.win.KeyboardEvent('keydown',{key:'Enter',bubbles:true}));
    trigger.dispatchEvent(new p.win.KeyboardEvent('keyup',{key:'Enter',bubbles:true}));
    await new Promise(resolve=>setTimeout(resolve,2100));assert(p.requests('/api/operations/prepare').length===0,'Short keyboard hold sent SOS');
    trigger.dispatchEvent(new p.win.MouseEvent('click',{detail:0,bubbles:true}));
    await wait(()=>p.requests('/api/operations/'+'a'.repeat(32)+'/execute').length===1,'AT activation did not reach the existing operation path');
    assert(p.requests('/api/emergency').length===0,'SOS used the legacy mutation endpoint');
  });
  await test('Language remains secondary and updates the visible purpose choices',async()=>{
    const p=await open([320,480]);const language=p.$('visitorLanguage');assert(language,'Language choice missing');
    language.value='zh';language.dispatchEvent(new p.win.Event('change',{bubbles:true}));
    await wait(()=>p.doc.documentElement.lang==='zh','Language not applied');
    p.doc.querySelector('[data-door]').click();assert(p.doc.querySelector('[data-purpose="delivery"]').textContent.includes('配送'),'Purpose not localized');
    const focused=p.doc.querySelector('[data-purpose="delivery"]');focused.focus();
    const count=p.requests('/api/panel/state').length;await wait(()=>p.requests('/api/panel/state').length>count,'Background snapshot missing');
    await new Promise(resolve=>setTimeout(resolve,30));assert(p.doc.activeElement===focused,'Background refresh removed purpose keyboard focus');
    assert(p.requests('/api/panel/press').length===0,'Language selection rang the door');
  });
  await test('Recovery and no-answer titles keep the existing call identity and terminal permissions',async()=>{
    const p=await open([320,480],{flow:'ring_then_purpose'});p.doc.querySelector('[data-door]').click();await wait(()=>!p.$('cancelCall').disabled,'Call not accepted');
    const id=p.f.state.doors[0].call_id;p.f.state.doors[0].recovery_required=true;
    await wait(()=>p.$('callingMsg').textContent.includes('Restoring'),'Recovery title missing');
    assert(!p.$('cancelCall').disabled,'Recovery removed visitor cancellation');
    const latePurpose=p.doc.querySelector('[data-purpose="delivery"]');
    p.f.state.doors[0].recovery_required=false;p.f.setCall('expired');await wait(()=>p.$('callingMsg').textContent==='No answer','No-answer state missing');
    assert(p.$('cancelCall').disabled&&p.f.state.doors[0].call_id===id,'Terminal state lost its identity or still allows an action');
    assert(p.$('purposeStep').style.display==='none','Terminal call still shows purpose mutations');
    latePurpose.onclick();assert(p.requests('/api/panel/purpose').length===0,'Late purpose action mutated a terminal call');
  });
  frames.innerHTML='';return results;
}
