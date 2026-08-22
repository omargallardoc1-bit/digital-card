(()=>{
  function addAudioLink(){
    if(document.getElementById('platform-audio-admin-link'))return;
    const headerActions=document.querySelector('.header-actions');
    if(headerActions){
      const button=document.createElement('button');
      button.id='platform-audio-admin-link';
      button.className='ghost';
      button.type='button';
      button.textContent='Audio extendido';
      button.onclick=()=>location.href='/platform-audio';
      headerActions.prepend(button);
    }
    const aside=document.querySelector('aside');
    if(aside){
      const navButton=document.createElement('button');
      navButton.id='platform-audio-admin-link-side';
      navButton.className='navbtn';
      navButton.type='button';
      navButton.textContent='Audio extendido';
      navButton.onclick=()=>location.href='/platform-audio';
      const account=aside.querySelector('.account');
      if(account)aside.insertBefore(navButton,account);else aside.appendChild(navButton);
    }
  }
  const observer=new MutationObserver(addAudioLink);
  observer.observe(document.documentElement,{childList:true,subtree:true});
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',addAudioLink);else addAudioLink();
})();