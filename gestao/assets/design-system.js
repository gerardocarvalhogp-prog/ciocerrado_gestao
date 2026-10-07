// Substitui confirm()/alert() nativos do navegador pelo padrão visual do
// sistema. Nativo trava a thread e dá o mesmo peso a "Cancelar" e a
// "Remover a cota" — ver auditoria de UX de 28/08/2026.
//
// Uso:
//   if (!(await DS.confirmar("Remover a cota?", {tom:"perigo"}))) return;
//   DS.avisar("Não foi possível salvar.", {tom:"erro"});
// esc/$/$$/rpc/explicar viviam copiados em cada uma das 5 telas
// (admin/portal/jantares/rooming/checkin) — idênticos, exceto por
// diferenças de formatação e pelas regras extras que cada tela
// acrescenta em explicar(). Centralizados aqui (revisão de arquitetura
// de 10/09/2026) pra não duplicar, e porque foi exatamente essa
// duplicação que abriu a divergência de escaping que causou o achado
// de XSS corrigido antes em avisar()/confirmar() — um esc() só, usado
// por tudo, fecha a causa na raiz.
//
// Ficam como globais soltos (não DS.esc etc.) de propósito: nenhuma
// tela usa <script type="module">, então toda variável de topo já é
// implicitamente global — manter o mesmo padrão evita reescrever
// centenas de call sites (esc(x), $(sel), rpc(nome,params)) por uma
// mudança que é só de onde o código mora, não de como se chama.
function esc(v) {
  return String(v ?? "").replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  }[c]));
}
window.esc = esc;

window.$ = (s, r = document) => r.querySelector(s);
window.$$ = (s, r = document) => [...r.querySelectorAll(s)];

// depende de `sb` (cliente Supabase) já existir no escopo global — cada
// tela cria o próprio `sb` antes de qualquer clique disparar uma
// chamada, então funciona mesmo definido aqui, num <script> carregado
// antes do que declara `sb`.
async function rpc(nome, params) {
  const { data, error } = await sb.rpc(nome, params);
  if (error) throw error;
  return data;
}
window.rpc = rpc;

// extras: array de [trecho, resposta] (ou [trecho, fn(m)]), checado
// ANTES das regras base — é como cada tela acrescenta as próprias
// regras (ex.: rooming.html e a data de nascimento das crianças) sem
// duplicar as regras comuns de login/sessão/acesso. Quem não passa
// extras (a maioria dos call sites) só usa a base, sem mudar nada.
function explicar(e, extras) {
  const m = e?.message || String(e);
  for (const [trecho, resposta] of extras || []) {
    if (m.includes(trecho)) return typeof resposta === "function" ? resposta(m) : resposta;
  }
  if (m.includes("Email not confirmed"))
    return "Confirme seu e-mail antes de entrar — enviamos um link de confirmação. Não achou? Confira o spam ou peça pra reenviar.";
  if (m.includes("Invalid login credentials")) return "E-mail ou senha incorretos.";
  if (m.includes("Acesso restrito a administradores")) return "Esta ação exige perfil de administrador.";
  if (m.includes("Acesso restrito")) return "Seu e-mail não está cadastrado na equipe.";
  if (m.includes("JWT") || m.includes("session")) return "Sua sessão expirou. Entre novamente.";
  return m;
}
window.explicar = explicar;

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
    const el = elemento(`<div class="ds-toast tom-${tom}" role="status">${esc(mensagem)}</div>`);
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
            <h2 id="ds-modal-titulo">${esc(titulo)}</h2>
            <p>${esc(mensagem)}</p>
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
    // mesma funcao que window.explicar, so' que acessivel por um nome
    // que uma tela com regras extras (rooming.html, portal.html) nao
    // corre risco de sobrescrever ao redeclarar o `explicar` global
    // proprio dela — DS.explicarBase nao muda, `explicar` bare muda.
    explicarBase: explicar,
  };
})();

// ---------------------------------------------------------------------
// Rótulo ligado ao campo — análise de design de 07/10/2026.
//
// Quase todo formulário do sistema escreve <label>Nome</label><input>
// lado a lado, sem `for`: na tela parece ligado, mas o leitor de tela
// não anuncia o que o campo pede e clicar no rótulo não foca o campo.
// Em vez de editar centenas de campos (muitos montados por innerHTML),
// liga aqui cada <label> sem `for` ao campo que vem logo depois dele —
// inclusive nos formulários desenhados depois da carga, via
// MutationObserver. Rótulo que já envolve o campo já é ligado; fica.
// ---------------------------------------------------------------------
(function () {
  let seq = 0;
  function ligarRotulos(raiz) {
    if (!raiz || !raiz.querySelectorAll) return;
    raiz.querySelectorAll("label:not([for])").forEach((l) => {
      if (l.querySelector("input,select,textarea")) return;
      const alvo = l.nextElementSibling;
      if (!alvo || !alvo.matches("input,select,textarea")) return;
      if (!alvo.id) alvo.id = "campo-ds-" + (++seq);
      l.htmlFor = alvo.id;
    });
  }
  function iniciar() {
    ligarRotulos(document);
    new MutationObserver((mudancas) => {
      for (const m of mudancas) {
        m.addedNodes.forEach((n) => {
          if (n.nodeType !== 1) return;
          ligarRotulos(n.parentNode || n);
        });
      }
    }).observe(document.body, { childList: true, subtree: true });
  }
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", iniciar);
  } else {
    iniciar();
  }
})();

// ---------------------------------------------------------------------
// Nome pra exibir — análise de design de 07/10/2026.
//
// O cadastro padroniza nome em CAIXA ALTA (trigger de 20260831170000,
// bom pra comparar e deduplicar), e isso vazava pra tela: "Olá, CARLOS",
// "CARLOS DIRETOR" ao lado de "Ana Souza" no check-in. Só pra mostrar:
// nome que vier inteiro em maiúsculas vira "Carlos Diretor", com
// da/de/do/das/dos/e em minúsculas. Nome com caixa mista (digitado por
// alguém) passa intacto — não sabemos melhor que quem digitou.
// ---------------------------------------------------------------------
function nomeExibicao(v) {
  const s = String(v ?? "").trim();
  if (!s || s !== s.toUpperCase() || s === s.toLowerCase()) return s;
  const miudas = new Set(["da", "de", "do", "das", "dos", "e"]);
  return s.toLowerCase().split(/\s+/).map((p, i) =>
    i > 0 && miudas.has(p) ? p : p.charAt(0).toUpperCase() + p.slice(1)
  ).join(" ");
}
window.nomeExibicao = nomeExibicao;

// Altura do cabeçalho pro menu lateral fixo de tela larga começar logo
// abaixo dele (ver design-system.css, @media min-width:1200px). O
// cabeçalho fica dentro de #app, escondido até o login — por isso
// ResizeObserver, e não uma medida só na carga.
(function () {
  function medir(topo) {
    if (topo.offsetHeight) {
      document.documentElement.style.setProperty("--ds-topo-altura", topo.offsetHeight + "px");
    }
  }
  function iniciar() {
    const topo = document.querySelector(".topo");
    if (!topo || !document.querySelector(".menu-nav")) return;
    medir(topo);
    if (window.ResizeObserver) new ResizeObserver(() => medir(topo)).observe(topo);
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", iniciar);
  else iniciar();
})();
