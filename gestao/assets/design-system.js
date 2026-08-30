// Substitui confirm()/alert() nativos do navegador pelo padrão visual do
// sistema. Nativo trava a thread e dá o mesmo peso a "Cancelar" e a
// "Remover a cota" — ver auditoria de UX de 28/08/2026.
//
// Uso:
//   if (!(await DS.confirmar("Remover a cota?", {tom:"perigo"}))) return;
//   DS.avisar("Não foi possível salvar.", {tom:"erro"});
(function () {
  function elemento(html) {
    const t = document.createElement("template");
    t.innerHTML = html.trim();
    return t.content.firstElementChild;
  }

  function garantirToasts() {
    let host = document.querySelector(".ds-toasts");
    if (!host) {
      host = elemento('<div class="ds-toasts" aria-live="polite" aria-atomic="true"></div>');
      document.body.appendChild(host);
    }
    return host;
  }

  function avisar(mensagem, opcoes) {
    opcoes = opcoes || {};
    const tom = opcoes.tom || "info";
    const host = garantirToasts();
    const el = elemento(`<div class="ds-toast tom-${tom}" role="status">${mensagem}</div>`);
    host.appendChild(el);
    requestAnimationFrame(() => el.classList.add("aberto"));
    const duracao = opcoes.duracao || 4200;
    setTimeout(() => {
      el.classList.remove("aberto");
      setTimeout(() => el.remove(), 200);
    }, duracao);
  }

  // Clique duplo num botão que abre confirmar() dispara o listener duas
  // vezes antes do primeiro clique sequer desabilitar o botão — sem essa
  // trava, cada chamada empilhava um <div class="ds-backdrop"> novo.
  let modalAberto = false;

  function confirmar(mensagem, opcoes) {
    if (modalAberto) return Promise.resolve(false);
    modalAberto = true;
    opcoes = opcoes || {};
    const titulo = opcoes.titulo || "Confirmar";
    const tom = opcoes.tom || "normal";
    const textoConfirmar = opcoes.textoConfirmar || "Confirmar";
    const textoCancelar = opcoes.textoCancelar || "Cancelar";
    return new Promise((resolve) => {
      const backdrop = elemento(`
        <div class="ds-backdrop">
          <div class="ds-modal tom-${tom}" role="alertdialog" aria-modal="true" aria-labelledby="ds-modal-titulo">
            <h2 id="ds-modal-titulo">${titulo}</h2>
            <p>${mensagem}</p>
            <div class="ds-modal-acoes">
              <button type="button" class="btn sec" data-acao="cancelar">${textoCancelar}</button>
              <button type="button" class="btn${tom === "perigo" ? " perigo" : ""}" data-acao="confirmar">${textoConfirmar}</button>
            </div>
          </div>
        </div>`);
      document.body.appendChild(backdrop);
      const focoAnterior = document.activeElement;
      requestAnimationFrame(() => backdrop.classList.add("aberto"));

      function fechar(resultado) {
        backdrop.classList.remove("aberto");
        document.removeEventListener("keydown", aoTeclar);
        modalAberto = false;
        setTimeout(() => {
          backdrop.remove();
          if (focoAnterior && focoAnterior.focus) focoAnterior.focus();
        }, 150);
        resolve(resultado);
      }

      function aoTeclar(ev) {
        if (ev.key === "Escape") fechar(false);
        if (ev.key === "Enter") fechar(true);
      }

      backdrop.addEventListener("click", (ev) => {
        if (ev.target === backdrop) fechar(false);
      });
      backdrop.querySelector('[data-acao="cancelar"]').addEventListener("click", () => fechar(false));
      backdrop.querySelector('[data-acao="confirmar"]').addEventListener("click", () => fechar(true));
      document.addEventListener("keydown", aoTeclar);
      backdrop.querySelector('[data-acao="confirmar"]').focus();
    });
  }

  function skeletonLinhas(n, altura) {
    n = n || 3;
    let html = "";
    for (let i = 0; i < n; i++) {
      html += `<div class="skeleton skeleton-linha"${altura ? ` style="height:${altura}px;"` : ""}></div>`;
    }
    return html;
  }

  function skeletonCartoes(n) {
    n = n || 3;
    let html = "";
    for (let i = 0; i < n; i++) {
      html += `<div class="skeleton skeleton-cartao" style="margin-bottom:8px;"></div>`;
    }
    return html;
  }

  function marcarInvalido(campoInput, mensagem) {
    campoInput.setAttribute("aria-invalid", "true");
    let erroEl = campoInput.parentElement.querySelector(".campo-erro");
    if (!erroEl) {
      erroEl = elemento(`<div class="campo-erro"></div>`);
      campoInput.insertAdjacentElement("afterend", erroEl);
    }
    if (!campoInput.id) campoInput.id = "campo-" + Math.random().toString(36).slice(2, 9);
    erroEl.id = campoInput.id + "-erro";
    campoInput.setAttribute("aria-describedby", erroEl.id);
    erroEl.textContent = mensagem;
    erroEl.classList.add("visivel");
  }

  function limparInvalido(campoInput) {
    campoInput.removeAttribute("aria-invalid");
    campoInput.removeAttribute("aria-describedby");
    const erroEl = campoInput.parentElement.querySelector(".campo-erro");
    if (erroEl) erroEl.classList.remove("visivel");
  }

  function focarPrimeiroInvalido(form) {
    const primeiro = form.querySelector('[aria-invalid="true"]');
    if (primeiro) primeiro.focus();
  }

  // Leitor de QR por camera — usado no check-in geral e na presenca por
  // atividade. Le o codigo, para a camera e fecha sozinho; devolve o
  // texto bruto do QR (o pessoa_key), quem chamou decide o que fazer
  // com ele. Depende de window.jsQR (carregado via script no <head>
  // de quem usa isto — checkin.html e admin.html).
  function lerQR(onLido) {
    if (typeof window.jsQR !== "function") {
      avisar("Leitor de QR não carregou. Recarregue a página.", { tom: "erro" });
      return;
    }

    const backdrop = elemento(`
      <div class="ds-backdrop">
        <div class="ds-modal ds-modal-qr">
          <h2>Ler crachá</h2>
          <p>Aponte a câmera para o QR do crachá.</p>
          <div class="ds-qr-video-wrap">
            <video autoplay playsinline muted></video>
          </div>
          <p class="ds-qr-erro"></p>
          <div class="ds-modal-acoes">
            <button type="button" class="btn sec" data-acao="cancelar">Cancelar</button>
          </div>
        </div>
      </div>`);
    document.body.appendChild(backdrop);
    requestAnimationFrame(() => backdrop.classList.add("aberto"));

    const video = backdrop.querySelector("video");
    const canvas = document.createElement("canvas");
    const ctx = canvas.getContext("2d", { willReadFrequently: true });
    let stream = null;
    let rafId = null;
    let parou = false;

    function parar() {
      if (parou) return;
      parou = true;
      if (rafId) cancelAnimationFrame(rafId);
      if (stream) stream.getTracks().forEach(t => t.stop());
      backdrop.classList.remove("aberto");
      setTimeout(() => backdrop.remove(), 150);
    }

    function tick() {
      if (parou) return;
      if (video.readyState === video.HAVE_ENOUGH_DATA) {
        canvas.width = video.videoWidth;
        canvas.height = video.videoHeight;
        ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
        const img = ctx.getImageData(0, 0, canvas.width, canvas.height);
        const codigo = window.jsQR(img.data, img.width, img.height);
        if (codigo && codigo.data) {
          parar();
          onLido(codigo.data);
          return;
        }
      }
      rafId = requestAnimationFrame(tick);
    }

    backdrop.querySelector('[data-acao="cancelar"]').addEventListener("click", parar);
    backdrop.addEventListener("click", e => { if (e.target === backdrop) parar(); });

    navigator.mediaDevices.getUserMedia({ video: { facingMode: "environment" } })
      .then(s => {
        if (parou) { s.getTracks().forEach(t => t.stop()); return; }
        stream = s;
        video.srcObject = s;
        rafId = requestAnimationFrame(tick);
      })
      .catch(() => {
        backdrop.querySelector(".ds-qr-erro").textContent =
          "Não consegui acessar a câmera. Verifique a permissão do navegador, ou digite o código manualmente.";
      });
  }

  window.DS = {
    confirmar,
    avisar,
    skeletonLinhas,
    skeletonCartoes,
    marcarInvalido,
    limparInvalido,
    focarPrimeiroInvalido,
    lerQR,
  };
})();
