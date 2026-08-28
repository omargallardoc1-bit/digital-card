// MX Business Card — colores oficiales de redes sociales.
(() => {
  const css=document.createElement('style');
  css.textContent=`
    .social-link[aria-label="Facebook"]{color:#1877F2!important}
    .social-link[aria-label="Instagram"]{color:#E4405F!important}
    .social-link[aria-label="LinkedIn"]{color:#0A66C2!important}
    .social-link[aria-label="YouTube"]{color:#FF0000!important}
    .social-link[aria-label="TikTok"]{color:#000000!important}
    .social-link[aria-label="X"],.social-link[aria-label="Twitter"]{color:#000000!important}
    .social-link[aria-label="Threads"]{color:#000000!important}
    .social-link[aria-label="Pinterest"]{color:#E60023!important}
    .social-link[aria-label="Telegram"]{color:#26A5E4!important}
    .social-link[aria-label="Snapchat"]{color:#FFFC00!important}
    .social-link[aria-label="Facebook"]:hover,.social-link[aria-label="Facebook"]:focus-visible{background:#EAF2FF!important;color:#1877F2!important}
    .social-link[aria-label="Instagram"]:hover,.social-link[aria-label="Instagram"]:focus-visible{background:#FFF0F5!important;color:#E4405F!important}
    .social-link[aria-label="LinkedIn"]:hover,.social-link[aria-label="LinkedIn"]:focus-visible{background:#EAF5FB!important;color:#0A66C2!important}
    .social-link[aria-label="YouTube"]:hover,.social-link[aria-label="YouTube"]:focus-visible{background:#FFF0F0!important;color:#FF0000!important}
    .social-link[aria-label="TikTok"]:hover,.social-link[aria-label="TikTok"]:focus-visible,.social-link[aria-label="X"]:hover,.social-link[aria-label="X"]:focus-visible,.social-link[aria-label="Twitter"]:hover,.social-link[aria-label="Twitter"]:focus-visible,.social-link[aria-label="Threads"]:hover,.social-link[aria-label="Threads"]:focus-visible{background:#F2F2F2!important;color:#000000!important}
    .social-link[aria-label="Pinterest"]:hover,.social-link[aria-label="Pinterest"]:focus-visible{background:#FFF0F2!important;color:#E60023!important}
    .social-link[aria-label="Telegram"]:hover,.social-link[aria-label="Telegram"]:focus-visible{background:#EDF8FD!important;color:#26A5E4!important}
    .social-link[aria-label="Snapchat"]:hover,.social-link[aria-label="Snapchat"]:focus-visible{background:#111!important;color:#FFFC00!important}
    .social-link svg{stroke:currentColor}
  `;
  document.head.appendChild(css);
})();
