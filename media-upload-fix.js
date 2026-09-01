(()=>{
  'use strict';

  let installed=false;

  function notify(message){
    if(typeof toast==='function')toast(message);
    else console.warn(message);
  }

  function install(){
    if(installed||typeof selectCardImage!=='function'||typeof uploadCardImage!=='function')return false;
    installed=true;
    const originalSelect=selectCardImage;

    window.selectCardImage=async function(event,kind){
      try{
        await originalSelect(event,kind);
        if(typeof state==='undefined'||!state?.pendingMedia?.[kind])return;
        if(!state?.card?.id){
          notify('Guarda primero la tarjeta para poder subir imágenes.');
          return;
        }
        await uploadCardImage(kind);
      }catch(error){
        console.error('No se pudo completar la carga de imagen.',error);
        notify('No se pudo completar la carga de imagen: '+(error?.message||'error desconocido'));
      }
    };

    return true;
  }

  if(!install()){
    const timer=setInterval(()=>{
      if(install())clearInterval(timer);
    },50);
    setTimeout(()=>clearInterval(timer),5000);
  }
})();
