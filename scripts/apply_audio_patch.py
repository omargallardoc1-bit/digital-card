from pathlib import Path

p = Path('index.html')
s = p.read_text(encoding='utf-8')

STYLE_MARK = '</head>'
STYLE = r'''  <style>
    .card-audio{display:grid;gap:var(--space-3)}
    .card-audio audio,.audio-editor audio{width:100%;height:42px}
    .audio-editor{display:grid;gap:var(--space-4)}
    .audio-editor-card{padding:var(--space-4);border:1px solid var(--border-default);border-radius:var(--radius-card);background:var(--surface-muted)}
    .audio-editor-card h3{margin:0 0 var(--space-2)}
    .audio-actions{display:flex;gap:var(--space-2);flex-wrap:wrap;margin-top:var(--space-3)}
    .audio-status{margin:0;color:var(--text-secondary);font-size:13px;line-height:20px}
    .audio-timer{font-variant-numeric:tabular-nums;font-weight:800;color:var(--semantic-danger)}
    @media(max-width:600px){.audio-actions button{flex:1 1 140px}}
  </style>
'''
if 'class="card-audio"' not in s and '.audio-editor{' not in s:
    if STYLE_MARK not in s: raise SystemExit('No se encontró </head>')
    s = s.replace(STYLE_MARK, STYLE + STYLE_MARK, 1)

old = "const blankCard=()=>({id:null,slug:'',name:'Nueva persona',role:'Profesional',company:'Nueva empresa',slogan:'Tu marca. Tu conexión.',about:'',phone:'',secondary_phone:'',wa:'',email:'',web:'',location:'',socials:emptySocials(),capture:false,status:'draft',photo_url:null,logo_url:null,cover_url:null,qr_settings:{...DEFAULT_QR_SETTINGS},photoSignedUrl:'',logoSignedUrl:'',coverSignedUrl:''});"
new = "const blankCard=()=>({id:null,slug:'',name:'Nueva persona',role:'Profesional',company:'Nueva empresa',slogan:'Tu marca. Tu conexión.',about:'',phone:'',secondary_phone:'',wa:'',email:'',web:'',location:'',socials:emptySocials(),capture:false,status:'draft',photo_url:null,logo_url:null,cover_url:null,audio_url:null,audio_duration_seconds:null,qr_settings:{...DEFAULT_QR_SETTINGS},photoSignedUrl:'',logoSignedUrl:'',coverSignedUrl:'',audioSignedUrl:''});"
if old in s: s=s.replace(old,new,1)
elif 'audio_duration_seconds:null' not in s: raise SystemExit('No se encontró blankCard')

old = "function cardFromRow(row){return {...blankCard(),...row,secondary_phone:row.secondary_phone||'',socials:{...emptySocials(),...(row.socials||{})},qr_settings:normalizeQrSettings(row.qr_settings),role:row.position||'',about:row.description||'',wa:row.whatsapp||'',web:row.website||'',capture:!!row.capture_enabled,photoSignedUrl:mediaUrlCache.get(row.photo_url)||'',logoSignedUrl:mediaUrlCache.get(row.logo_url)||'',coverSignedUrl:mediaUrlCache.get(row.cover_url)||''};}"
new = "function cardFromRow(row){return {...blankCard(),...row,secondary_phone:row.secondary_phone||'',socials:{...emptySocials(),...(row.socials||{})},qr_settings:normalizeQrSettings(row.qr_settings),role:row.position||'',about:row.description||'',wa:row.whatsapp||'',web:row.website||'',capture:!!row.capture_enabled,photoSignedUrl:mediaUrlCache.get(row.photo_url)||'',logoSignedUrl:mediaUrlCache.get(row.logo_url)||'',coverSignedUrl:mediaUrlCache.get(row.cover_url)||'',audioSignedUrl:mediaUrlCache.get(row.audio_url)||''};}"
if old in s: s=s.replace(old,new,1)
elif 'audioSignedUrl:mediaUrlCache.get(row.audio_url)' not in s: raise SystemExit('No se encontró cardFromRow')

old = "async function resolveCardMedia(card){const resolved={...card};await Promise.all(Object.values(mediaSettings).map(async settings=>{resolved[settings.signed]=await signedMediaUrl(resolved[settings.column])}));return resolved}"
new = "async function resolveCardMedia(card){const resolved={...card};await Promise.all(Object.values(mediaSettings).map(async settings=>{resolved[settings.signed]=await signedMediaUrl(resolved[settings.column])}));resolved.audioSignedUrl=await signedMediaUrl(resolved.audio_url);return resolved}"
if old in s: s=s.replace(old,new,1)
elif 'resolved.audioSignedUrl=await signedMediaUrl(resolved.audio_url)' not in s: raise SystemExit('No se encontró resolveCardMedia')

old = "function clearPendingMedia(){Object.keys(state.pendingMedia).forEach(releasePendingMedia)}"
new = "function clearPendingMedia(){Object.keys(state.pendingMedia).forEach(releasePendingMedia);releasePendingAudio()}"
if old in s: s=s.replace(old,new,1)
elif 'releasePendingAudio()' not in s: raise SystemExit('No se encontró clearPendingMedia')

old = "editorBlock('media','Imágenes',mediaEditor(),false,6)+editorBlock('qr','QR',qrCard(state.card,'editor'),false,7)"
new = "editorBlock('media','Imágenes',mediaEditor(),false,6)+editorBlock('audio','Audio',audioEditor(),false,7)+editorBlock('qr','QR',qrCard(state.card,'editor'),false,8)"
if old in s: s=s.replace(old,new,1)
elif "editorBlock('audio','Audio'" not in s: raise SystemExit('No se encontró la secuencia de bloques del editor')

old = "</section>${customButtonsPreview(c)}${about?"
new = "</section>${audioPreview(c)}${customButtonsPreview(c)}${about?"
if old in s: s=s.replace(old,new,1)
elif '${audioPreview(c)}${customButtonsPreview(c)}' not in s: raise SystemExit('No se encontró el punto de inserción en phonePreview')

anchor = "  function field(key,label,type='text',maxLength=null,help=''){"
AUDIO_CODE = r'''  let pendingAudio=null,audioRecorder=null,audioRecorderStream=null,audioChunks=[],audioRecordingStartedAt=0,audioRecordingTimer=null;
  const AUDIO_MAX_SECONDS=30,AUDIO_MAX_BYTES=5*1024*1024,AUDIO_TYPES=new Set(['audio/mpeg','audio/mp4','audio/x-m4a','audio/webm']);
  function audioLabels(){return language==='en'?{title:'Audio introduction',empty:'No audio uploaded',help:'Upload or record an introduction of up to 30 seconds (maximum 5 MB).',upload:'Upload audio',record:'Record',stop:'Stop',remove:'Remove',pending:'Ready to upload',current:'Current audio'}:{title:'Audio de presentación',empty:'Sin audio cargado',help:'Sube o graba una presentación de hasta 30 segundos (máximo 5 MB).',upload:'Subir audio',record:'Grabar',stop:'Detener',remove:'Eliminar',pending:'Listo para subir',current:'Audio actual'}}
  function audioPreview(c){if(!c.audioSignedUrl)return '';const l=audioLabels();return `<section class="card-section card-audio"><h2 class="card-section-title">${l.title}</h2><audio controls preload="metadata" src="${esc(c.audioSignedUrl)}">Tu navegador no soporta audio.</audio></section>`}
  function formatAudioSeconds(value){const seconds=Math.max(0,Math.min(AUDIO_MAX_SECONDS,Math.round(Number(value)||0)));return `00:${String(seconds).padStart(2,'0')}`}
  function audioEditor(){const l=audioLabels(),editable=canEditCurrentCardContent(),disabled=!state.card.id,current=state.card.audioSignedUrl,pending=pendingAudio?.previewUrl||'';return `<div class="audio-editor"><p class="copy-flush">${l.help}</p><div class="audio-editor-card"><h3>${l.title}</h3>${pending?`<p class="audio-status"><b>${l.pending}</b> · ${formatAudioSeconds(pendingAudio.duration)}</p><audio controls preload="metadata" src="${esc(pending)}"></audio>`:current?`<p class="audio-status"><b>${l.current}</b> · ${formatAudioSeconds(state.card.audio_duration_seconds)}</p><audio controls preload="metadata" src="${esc(current)}"></audio>`:`<p class="audio-status">${l.empty}</p>`}${editable?`<div class="field" style="margin-top:var(--space-3)"><label for="card-audio-file">${l.upload}</label><input id="card-audio-file" type="file" accept="audio/mpeg,audio/mp4,audio/x-m4a,audio/webm,.mp3,.m4a,.mp4,.webm" onchange="selectAudioFile(event)" ${disabled?'disabled':''}></div><div class="audio-actions"><button class="ghost" type="button" onclick="startAudioRecording()" ${disabled||audioRecorder?'disabled':''}>🎙️ ${l.record}</button><button class="ghost" type="button" onclick="stopAudioRecording()" ${audioRecorder?'':'disabled'}>⏹ ${l.stop}</button><button class="primary" type="button" onclick="uploadCardAudio()" ${disabled||!pendingAudio?'disabled':''}>${l.upload}</button><button class="danger" type="button" onclick="removeCardAudio()" ${disabled||!state.card.audio_url?'disabled':''}>${l.remove}</button></div><p class="audio-status" id="audio-recording-status">${audioRecorder?`<span class="audio-timer">● ${formatAudioSeconds((Date.now()-audioRecordingStartedAt)/1000)}</span> / 00:30`:''}</p>`:'<p class="media-help">Solo lectura.</p>'}</div></div>`}
  function releasePendingAudio(){if(pendingAudio?.previewUrl)URL.revokeObjectURL(pendingAudio.previewUrl);pendingAudio=null}
  function normalizedAudioType(file){const type=String(file.type||'').toLowerCase();if(AUDIO_TYPES.has(type))return type;const name=String(file.name||'').toLowerCase();if(name.endsWith('.mp3'))return 'audio/mpeg';if(name.endsWith('.m4a')||name.endsWith('.mp4'))return 'audio/mp4';if(name.endsWith('.webm'))return 'audio/webm';return ''}
  function audioExtension(type,fileName=''){if(type==='audio/mpeg')return 'mp3';if(type==='audio/webm')return 'webm';if(type==='audio/x-m4a')return 'm4a';if(type==='audio/mp4')return String(fileName).toLowerCase().endsWith('.m4a')?'m4a':'mp4';return 'webm'}
  async function measureAudioDuration(blob){const url=URL.createObjectURL(blob);try{return await new Promise((resolve,reject)=>{const audio=document.createElement('audio');audio.preload='metadata';audio.onloadedmetadata=()=>Number.isFinite(audio.duration)&&audio.duration>0?resolve(audio.duration):reject(new Error('No se pudo determinar la duración del audio.'));audio.onerror=()=>reject(new Error('El archivo no contiene un audio válido.'));audio.src=url})}finally{URL.revokeObjectURL(url)}}
  async function setPendingAudio(blob,type,ext,duration=null){if(blob.size>AUDIO_MAX_BYTES)throw new Error('El audio supera el límite de 5 MB.');const measured=duration||await measureAudioDuration(blob);if(!Number.isFinite(measured)||measured<=0||measured>AUDIO_MAX_SECONDS+.25)throw new Error('El audio debe durar como máximo 30 segundos.');releasePendingAudio();pendingAudio={blob,type,ext,duration:Math.max(1,Math.min(AUDIO_MAX_SECONDS,Math.ceil(measured))),previewUrl:URL.createObjectURL(blob)};render()}
  async function selectAudioFile(event){if(!canEditCurrentCardContent())return;const file=event.target.files?.[0];if(!file)return;const type=normalizedAudioType(file);if(!type){toast('Formato de audio no permitido. Usa MP3, M4A/MP4 o WebM.');return}try{await setPendingAudio(file,type,audioExtension(type,file.name))}catch(error){toast(error.message||'No se pudo procesar el audio.')}}
  async function startAudioRecording(){if(!state.card.id||!canEditCurrentCardContent())return;if(!navigator.mediaDevices?.getUserMedia||typeof MediaRecorder==='undefined'){toast('Este navegador no permite grabar audio.');return}try{audioRecorderStream=await navigator.mediaDevices.getUserMedia({audio:true});const preferred=['audio/webm;codecs=opus','audio/mp4'];const mime=preferred.find(type=>MediaRecorder.isTypeSupported?.(type))||'';audioChunks=[];audioRecorder=new MediaRecorder(audioRecorderStream,mime?{mimeType:mime}:undefined);audioRecordingStartedAt=Date.now();audioRecorder.ondataavailable=e=>{if(e.data?.size)audioChunks.push(e.data)};audioRecorder.onstop=async()=>{const elapsed=Math.min(AUDIO_MAX_SECONDS,(Date.now()-audioRecordingStartedAt)/1000);const rawType=(audioRecorder?.mimeType||audioChunks[0]?.type||'audio/webm').split(';')[0];const type=AUDIO_TYPES.has(rawType)?rawType:(rawType==='audio/mp4'?'audio/mp4':'audio/webm');const blob=new Blob(audioChunks,{type});audioRecorderStream?.getTracks().forEach(track=>track.stop());audioRecorderStream=null;audioRecorder=null;clearInterval(audioRecordingTimer);audioRecordingTimer=null;try{await setPendingAudio(blob,type,audioExtension(type),elapsed)}catch(error){toast(error.message||'No se pudo preparar la grabación.')}};audioRecorder.start(250);audioRecordingTimer=setInterval(()=>{const elapsed=(Date.now()-audioRecordingStartedAt)/1000,status=document.getElementById('audio-recording-status');if(status)status.innerHTML=`<span class="audio-timer">● ${formatAudioSeconds(elapsed)}</span> / 00:30`;if(elapsed>=AUDIO_MAX_SECONDS)stopAudioRecording()},250);render()}catch(error){audioRecorderStream?.getTracks().forEach(track=>track.stop());audioRecorderStream=null;audioRecorder=null;toast('No se pudo acceder al micrófono. Revisa el permiso del navegador.')}}
  function stopAudioRecording(){if(audioRecorder&&audioRecorder.state!=='inactive')audioRecorder.stop()}
  async function uploadCardAudio(){if(!pendingAudio||!state.session||!state.card.id||!canEditCurrentCardContent())return;const card=state.card,oldPath=card.audio_url||null,path=`${card.owner_id||state.session.user.id}/${card.id}/audio/${crypto.randomUUID()}.${pendingAudio.ext}`;const {error:uploadError}=await db.storage.from(MEDIA_BUCKET).upload(path,pendingAudio.blob,{contentType:pendingAudio.type,cacheControl:'3600',upsert:false});if(uploadError){toast('No se pudo subir el audio: '+uploadError.message);return}const {data,error}=await db.rpc('set_card_audio_reference',{target_card_id:card.id,object_path:path,duration_seconds:pendingAudio.duration});if(error){await db.storage.from(MEDIA_BUCKET).remove([path]);toast('No se pudo guardar el audio: '+error.message);return}const row=Array.isArray(data)?data[0]:data;if(!row?.id){await db.storage.from(MEDIA_BUCKET).remove([path]);toast('La operación no devolvió una tarjeta válida.');return}releasePendingAudio();const resolved=await resolveCardMedia(cardFromRow(row));updateCardMediaState(resolved);if(oldPath&&oldPath!==path){mediaUrlCache.delete(oldPath);const {error:cleanupError}=await db.storage.from(MEDIA_BUCKET).remove([oldPath]);if(cleanupError){render();toast('Audio actualizado; el archivo anterior requiere limpieza.');return}}render();toast(language==='en'?'Audio updated successfully.':'Audio actualizado correctamente.')}
  async function removeCardAudio(){const card=state.card;if(!card.id||!card.audio_url||!canEditCurrentCardContent())return;const oldPath=card.audio_url;const {data,error}=await db.rpc('set_card_audio_reference',{target_card_id:card.id,object_path:null,duration_seconds:null});if(error){toast('No se pudo eliminar el audio: '+error.message);return}const row=Array.isArray(data)?data[0]:data;if(!row?.id){toast('La operación no devolvió una tarjeta válida.');return}releasePendingAudio();mediaUrlCache.delete(oldPath);const resolved=await resolveCardMedia(cardFromRow(row));updateCardMediaState(resolved);const {error:removeError}=await db.storage.from(MEDIA_BUCKET).remove([oldPath]);render();toast(removeError?'La referencia se eliminó, pero el archivo requiere limpieza.':(language==='en'?'Audio removed successfully.':'Audio eliminado correctamente.'))}
'''
if 'function audioEditor()' not in s:
    if anchor not in s: raise SystemExit('No se encontró el ancla antes de field()')
    s=s.replace(anchor,AUDIO_CODE+anchor,1)

p.write_text(s,encoding='utf-8')
print('Parche de audio aplicado correctamente.')
