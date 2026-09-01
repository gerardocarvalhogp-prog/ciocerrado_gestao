# Módulos previstos, ainda não disponíveis

**Os três módulos que este arquivo descrevia como "nada existe na interface"
já estão construídos, com tela, em produção.** Achado central desta apuração
— ver `10-admin.md`, `40-checkin.md` e `80-integracoes.md` para onde cada
pedaço foi movido. O que resta aqui é só a fração de cada módulo que
continua genuinamente bloqueada por algo fora do código.

---

## 1. Acompanhamento e cobrança de pendências — **construído**

Aba **Acompanhamento**, em `admin.html`. Movido para `10-admin.md`.

Tudo que a especificação original pedia está lá: pendência por etapa e por
pessoa/empresa, tempo em aberto, atraso contra o prazo configurado, decisão de
cobrança sempre humana (rascunho de e-mail preparado, organizador revisa e
confirma o envio, "Enviar agora" por pessoa — nunca "cobrar todos").

**O que não pude confirmar:** se os textos de cobrança são editáveis como
modelo reutilizável, ou digitados na hora a cada envio — o modal mostra um
rascunho pré-preenchido e editável por aquele envio, não achei um cadastro de
"modelos" à parte. Ver `PERGUNTAS.md`.

---

## 2. Presença, QR code e WhatsApp — **construído em duas partes, uma ainda bloqueada**

### Atividades e presença — construído

Aba **Atividades**, em `admin.html`. Cadastro de atividade por evento, liga/
desliga por evento, check-in específico por atividade — movido para
`10-admin.md`.

### QR code — construído

`checkin.html` já lê QR pela câmera do celular (`jsQR`), botão "Ler QR" —
movido para `40-checkin.md`. **Não confirmado:** se o mesmo leitor já troca de
contexto entre chegada geral e presença por atividade, como a especificação
original pedia — o código de `checkin.html` lido nesta passagem cobre chegada
geral; o check-in por atividade em `admin.html` usa suas próprias funções
(`atividade_checkin_registrar`), e não confirmei se compartilha o mesmo
componente de leitura ou se são dois leitores distintos.

### WhatsApp — genuinamente ainda não disponível, mas o código existe

Continua **previsto, não disponível** — nisso o rascunho estava certo. O que
mudou: a Edge Function `enviar-whatsapp` já existe, pronta, e recusa rodar
com uma mensagem clara do motivo (mesmo padrão de `enviar-notificacoes`,
que recusa sem `RESEND_API_KEY`). Falta, fora de código:

1. Verificação de negócio no WhatsApp Business Platform (Meta Business
   Manager).
2. Número de telefone dedicado aprovado dentro dessa conta.
3. Pelo menos um template de mensagem aprovado pela Meta — fora da janela de
   24h aberta pelo destinatário, toda mensagem tem que ser um template
   pré-aprovado, não existe texto livre para cobrança proativa.
4. Opt-in explícito de quem recebe (LGPD + política do WhatsApp).

Nenhuma das quatro depende deste repositório. O primeiro aviso automático de
atraso (~15 min, "já estamos começando") e o aviso pessoal com confirmação do
organizador (1–2h) seguem como desenho, não implementação — a fila de
notificação (`notificacoes.canal`) já aceita `whatsapp` como valor, mas nada
dispara enquanto a conta não existir.

*A confirmar: andamento da verificação da conta WhatsApp Business — é
dependência externa com prazo próprio, não rastreável pelo código.*

---

## 3. Integração com o app do evento — **parcialmente construído, o resto genuinamente bloqueado pelo parceiro**

### Cenário A (arquivo melhorado) — construído

Dentro da aba **Equipe**, seção "App do evento", em `admin.html`. Movido para
`10-admin.md` e `80-integracoes.md`.

- `eventos.id_app`: ID do evento no admin do parceiro, preenchido à mão (o
  app não expõe consulta).
- `mapa_empresa_app`: de-para entre empresa/patrocinador interno e o
  `empresa_id_app` numérico do parceiro, também preenchido à mão.
- Com isso, o sistema gera a planilha de usuários e de empresas **já no
  formato exato que o app aceita**, incluindo o ID certo por linha — a
  melhoria real possível sem depender do parceiro construir nada.

Regras do processo mantidas: registros sem e-mail são excluídos da
importação; registros novos entram ao final do arquivo.

### Cenário B/C (API de verdade) — continua bloqueado, e por razão confirmada

**Não é falta de tempo deste lado — o app do parceiro não tem API.**
Levantamento próprio confirmou: sem consulta de empresa por ID, sem upsert
(reenviar e-mail já existente é rejeitado, não atualizado), só importação de
planilha. Enquanto isso não mudar do lado do parceiro, envio automático e
retorno de dados para o sistema seguem impossíveis — não é uma prioridade a
reordenar, é uma dependência externa sem solução deste lado.

A "chave de identificação estável" que destravaria isso é exatamente o que
`mapa_empresa_app` já resolve manualmente — se o parceiro abrir uma API um
dia, a peça que falta é só o lado de fora.

---

## Resumo do que ainda é "previsto, não disponível" de verdade

| Item | Situação |
|---|---|
| WhatsApp (envio) | Código pronto, bloqueado por verificação de conta + template, ambos com a Meta |
| Integração automática com o app do evento (API) | Bloqueada pelo parceiro, que não tem API — não há o que fazer deste lado agora |
| QR com contexto trocável (chegada vs. atividade) | Não confirmado se já funciona assim ou se são dois componentes separados |

Tudo o que este arquivo descrevia além disso já está em produção.

---

## A confirmar com o organizador

- Se o modal de cobrança da aba Acompanhamento deveria ter modelos salvos e
  reutilizáveis, em vez de rascunho editável a cada envio.
- Andamento da verificação da conta WhatsApp Business.
- Se há qualquer sinalização recente do parceiro do app sobre construir uma
  API — se não, não há necessidade de revisitar isto tão cedo.
- Se o QR de `checkin.html` e o check-in por atividade de `admin.html`
  deveriam compartilhar o mesmo componente de leitura.
