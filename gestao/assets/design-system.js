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

  function confirmar(mensagem, opcoes) {
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

  window.DS = {
    confirmar,
    avisar,
    skeletonLinhas,
    skeletonCartoes,
    marcarInvalido,
    limparInvalido,
    focarPrimeiroInvalido,
  };
})();
