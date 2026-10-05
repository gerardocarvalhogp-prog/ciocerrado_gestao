# CIO Cerrado — Sistema de Gestão

Contexto para o Claude Code. Leia antes de mexer em qualquer coisa.

## O que é

Sistema integrado de gestão dos eventos do CIO Cerrado (comunidade de líderes de
tecnologia do Centro-Oeste, 300+ membros). Cobre o fluxo completo de um evento:

```
inscrição (Sympla) → contrato (Autentique) → rooming list → fatura adicional/transfer
      → portal de patrocinadores (cotas, quartos, brindes) → etiquetas
      → exportação para o app do evento → jantares e eventos menores
```

Primeiro evento atendido: **CIO Cerrado Experience 2026** (12–16/08/2026, Tauá Resort
Alexânia; transfers saindo de GYN e BSB; ~130 CIOs + acompanhantes + 61 patrocinadores).

Hoje boa parte disso roda em scripts Python avulsos (pipeline `rotina_cerrado.py`:
fichas → mapa → etiquetas → contratos) mais planilhas. O objetivo do sistema é
substituir o trabalho manual e o "Mapa de Alocações" como fonte de verdade.

## Stack

- **Banco/back:** Supabase (Postgres), RLS ligada, lógica em funções SQL (RPC)
- **Auth:** Supabase Auth com magic link
- **E-mail transacional:** Resend, via Edge Function
- **Front:** HTML/JS estático + `supabase-js` (sem framework); planilhas no navegador com SheetJS
- **Deploy:** Netlify (site estático)

Essa stack veio do sistema de agendamento de massagem, que já está em produção
(`https://ciocerrado.netlify.app/`) e serve de referência de padrão.

## Decisões já fechadas

- O sistema vive num **schema próprio `gestao`**, dentro do **mesmo projeto Supabase**
  do sistema de massagem. Motivo: os nomes de tabela colidiam com os do `public`
  (`eventos`, `participantes`, `reservas`, `admins`). Não mexer no `public` — ele é o
  sistema de massagem em produção. A regra foi quebrada **uma vez**, de propósito e
  documentado, em `migrations/20260825090100`: uma view de lá vazava dado pessoal para
  `anon`. Se for quebrar de novo, que seja com o mesmo nível de justificativa.
- **Patrocinador tem múltiplos usuários com login** (não um login único por empresa).
- **Multievento por padrão.** Nada hardcoded para o Experience 2026. Um link por evento
  (`?evento=slug`), admins globais, importação por planilha modelo com linha de exemplo.
- **Jantares e eventos menores** reaproveitam a lógica de alocação já usada nas mesas
  redondas (ver abaixo).
- Primeiro evento atendido de verdade: o **Experience 2027**. O de 2026 já aconteceu,
  no fluxo antigo de planilhas — este sistema nasceu para a edição seguinte.

## Regras de negócio herdadas (mesas redondas → jantares)

A alocação de convidados a mesas/jantares combina três camadas, nesta ordem:

1. **Indicação direta** — se o patrocinador indicou a pessoa no PERFIL, ela vai para a
   mesa dele. Patrocinador também pode escolher os próprios convidados.
   A indicação é **reserva com janela**: o indicado some da lista das outras empresas
   enquanto a cota de quem indicou estiver na janela dela. Vencida, a fila anda, a reserva
   cai e a cota atrasada sai daquela sessão. Vale nos dois sentidos da fila — o indicado
   pela Prata resiste à Esmeralda.
   A janela é relativa (`cotas.janela_horas`, contadas do fim da cota anterior), ancorada
   em `eventos.escolha_abre_em`. Âncora vazia = nada expira.
2. **Porte** — empresas de maior faturamento vão para as cotas mais altas, na ordem
   Esmeralda → Diamante → Platina → Ouro → Prata. Faturamento vem do export "Lista de
   participantes" do Sympla.
3. **Afinidade** — dentro da cota, casa o que o patrocinador vende com o perfil do
   convidado (ex.: fornecedor de varejo com CIO de varejo).

Regra de Gov: órgãos públicos ficam fora de Esmeralda e Diamante e só entram por
indicação no PERFIL — o "faturamento" deles é orçamento, não receita, e não vale para o
ranking de porte. Há erro de cadastro conhecido na origem (segmento declarado na
inscrição vem errado em alguns casos), então o segmento precisa ser corrigível na mão.

Sem repetir o mesmo convidado na mesma mesa em dias diferentes.

## Convenções

- Toda mudança de banco entra como **migration versionada** (Supabase CLI), não `.sql`
  solto rodado no painel.
- Lógica sensível (reserva, alocação, contagem de cota) fica em **função SQL**, não no
  front — o front é estático e não dá pra confiar nele.
- Reserva/atribuição concorrente usa `SELECT ... FOR UPDATE` na linha do recurso.
- Toda função administrativa checa papel (`_exige_admin()` / `_exige_staff()` /
  `_exige_patrocinador()`) na **primeira linha**. Não é convenção: é a única proteção,
  porque nenhum papel lê tabela direto. O sistema de massagem já usa papéis separados (`admin` completo vs `checkin`
  restrito) — seguir o mesmo modelo.
- Documentos (CPF/e-mail) são normalizados antes de comparar: minúsculo, sem espaço,
  sem acento, só dígitos no CPF.
- Textos de interface em português do Brasil.

## Integrações e gotchas conhecidos

- **Sympla:** a API não é acessível de dentro do ambiente do Claude (chat). Trabalhar
  com export `.xlsx` ou script rodando na máquina do Gerardo.
- **Criação de evento no Sympla é manual.** Já existiu um robô de navegador
  (`rpa_sympla_jantares.py`, Playwright) pra criar evento e mandar convite — abandonado
  em 21/09/2026, instável demais (painel muda sem aviso, login com OTP em duas etapas).
  O organizador cria e publica o evento e manda convite direto no painel do Sympla;
  o sistema só guarda o link (`jantares.sympla_url`, `jantares.html`) e acompanha quem
  confirmou/recusou pela API pública de leitura (`integracao.py --jantares`, já
  automático). Não propor de novo automação de navegador pra isso sem pedir antes.
- **Autentique:** geração e envio de contratos. O pipeline atual roda em **sandbox por
  padrão**; produção é flag explícita. Manter esse comportamento.
- **Google Drive:** conta de serviço `robo-fichas` só tem leitura e **não tem cota para
  upload em My Drive** (403 `storageQuotaExceeded`) — upload usa OAuth de usuário.
- **E-mail corporativo @ciocerrado.com.br** fica na **Skymail**, não no Google Workspace;
  a rede do escritório às vezes bloqueia portas SMTP de saída. Preferir Resend/API.
- Rooming list: patrocinadores costumam preencher a coluna "Associação" com o nome da
  empresa em vez do número, agrupando tudo num bloco só. O sistema deve validar isso na
  entrada, em vez de deixar para a revisão manual.

## Fontes de dados de hoje (a substituir)

- "Mapa de Alocações – Tauá/Alexânia 2026" — abas ROOMING, COTAS, Resumo, Alexânia 1 e 2
- Export "Lista de participantes" do Sympla — faturamento, orçamento de TI, nº de
  colaboradores, segmento, autorização de uso do resultado analítico
- Fichas de check-in no Drive, por pasta (gestores / patrocinadores / staff)

## Estado atual

Números do schema `gestao`, conferidos no banco hospedado em 25/08/2026:
**29 tabelas, 6 views, 368 colunas, 143 funções, 37 políticas de RLS,
8 migrations.** Desatualizado — são **141 migrations** em 05/10/2026, mas os
outros números (tabelas/views/colunas/funções/políticas) não foram reconferidos
desde então porque exigem consulta ao catálogo do banco hospedado, que este
arquivo não tem como fazer sozinho. Antes de confiar nesses quatro números,
rode de novo a consulta do README §8.

- [x] Banco, funções e RLS
- [x] Front: portal do patrocinador, rooming, admin, check-in, jantares
- [x] **Uma linhagem só** — o `db reset` local reproduz o hospedado
      coluna a coluna, função a função, política a política.
      **Quebrado desde 29/09:** migrations de dado que fazem `raise
      exception` quando não acham a linha param o reset num banco vazio
      (ver `supabase/tests/LEIA-ME.md` pro contorno)
- [x] Publicado em `https://ciocerrado.netlify.app/gestao/`
- [x] Rastreio de brindes, da promessa até a entrega no quarto
- [x] Pagamento da fatura — já existia (aba Financeiro, `admin_marcar_fatura` /
      `admin_definir_pagamento_patrocinador`); o item ficou marcado como
      pendente por desatualização deste checklist, não por faltar.
- [x] Webhook do Autentique — Edge Function `autentique-webhook` +
      `webhook_contrato_assinado`. **Testado de ponta a ponta em produção em
      01/10/2026**: endpoint cadastrado no painel do Autentique (evento
      `signature.accepted`), contrato assinado no sandbox do Autentique
      refletiu "assinado" no painel sem rodar `--status`, com o link do PDF
      assinado também aparecendo. `verify_jwt = false` precisa estar ligado
      nessa function (`supabase/config.toml`) — sem isso o gateway do
      Supabase recusa a chamada do Autentique antes dela chegar no código.
- [x] Espelho de quartos do resort — mecanismo existe desde 26/08
      (`admin_importar_mapa_quartos`, prédio/andar/corredor/categoria física) e
      ganhou exportação no mesmo formato em 01/10 (`exportarMapaDeQuartos`,
      aba Quartos). Falta só reimportar o mapa real do Tauá para a edição
      2027 quando o resort mandar — o de 2026 foi só o exemplo usado pra
      validar o formato.
- [x] Limite de vagas e duplicidade de CIO nas mesas/jantares (01/10) —
      `admin_adicionar_convidado_sessao` passou a respeitar `sessoes.vagas` e
      a recusar o mesmo CIO confirmado em duas sessões do mesmo tipo; busca
      (`admin_buscar_participantes_sessao`) só oferece quem pode entrar de
      verdade. Coberto por teste automatizado (`supabase/tests/12`).
- [x] Quarto "quádruplo" (capacidade 4) como tipo válido em todo o sistema
      (01/10) — coberto por `supabase/tests/12`.
- [x] Mailing list e pesquisa de perfil num relatório só (01–05/10) —
      `admin_rel_pesquisa` ganhou o tipo de ingresso e virou a fonte do
      mailing, com os campos da pesquisa (faturamento, orçamento de TI,
      áreas de investimento) achatados em colunas. Desde 05/10,
      `integracao.py --sympla` importa a pesquisa sozinho, lendo o
      `custom_form` que a API do Sympla já devolve — **mas isso nunca rodou
      de verdade em produção ainda**, só testado isoladamente com dado
      fictício.

### Achados de 01/10/2026

- **Domínio não verificado no Resend — ainda sem solução, depende do
  organizador** (ver "O que depende do organizador" abaixo): a conta só
  deixa mandar e-mail pro próprio endereço da conta
  (`gerardocarvalhogp@gmail.com`) até `ciocerrado.com.br` ser verificado
  em resend.com/domains (registros SPF/DKIM, DNS fica na Skymail). Até
  lá, todo aviso real (contrato enviado/assinado, rooming confirmado)
  falha com 403 pra qualquer destinatário que não seja essa conta —
  bloqueia o uso de verdade do botão "Enviar toda a fila" (aba Equipe).
- **`?evento=` ausente na URL caía num evento errado, silenciosamente —
  CORRIGIDO no mesmo dia**:
  `rooming.html` e `portal.html` tinham `|| "cerrado2027"` como fallback
  quando a URL não trazia o evento — um CIO/patrocinador que caísse ali sem
  o parâmetro (link quebrado, redirect de confirmação que perde a query
  string) via silenciosamente os dados do evento de produção em vez de um
  erro claro. Corrigido: as duas telas agora bloqueiam com mensagem
  explícita ("Link incompleto") em vez de adivinhar o evento.
  `admin.html`/`checkin.html` têm o mesmo padrão mas não foram mexidas —
  são operadas por equipe logada com seletor de evento visível, risco bem
  menor que um link de e-mail de uso único.

### O que está verificado e o que não está

Conferido no banco local (`supabase db reset` + `supabase/tests/`):

- o baseline sobe do zero e o resultado bate com o hospedado
- os arquivos de teste (`01` a `23`) exercitam portal, rooming, fila da
  mesa redonda, fatura, reserva com janela, brindes, quarto de equipe,
  admin-only no "App do evento", staff escopado por evento, e (desde
  05/10) limite de vaga + duplicidade de CIO na mesa/jantar + quarto
  quádruplo — trocando de papel com `request.jwt.claims`, como o
  PostgREST faz
- fatura complementar cobra a diferença, é idempotente no recálculo e
  vira crédito quando alguém sai depois de pagar
- a reserva da indicação resiste de baixo para cima: o indicado pela
  Ouro não aparece para a Esmeralda

**Lacuna de 31/08 a 05/10 fechada em 05/10/2026** (`supabase/tests/13`
a `23`, todos transacionais, cada um com evento próprio — não dependem
de dado do banco). Das 81 migrations do intervalo (`20260831170000`
a `20261001280000`), **61 são de schema/comportamento** e todas têm teste agora
— 3 já estavam no `12`, as outras 58 nos arquivos novos; **20 são de
DADO** (vincular CIO de teste por nome, resetar contrato de teste, limpar
fila do hospedado...) e não têm teste por natureza: dependem de linha que
só existe no hospedado. Única parte de comportamento sem cobertura: a
**corrida** de `_garantir_reserva` (20260918090000) — o teste prova que
ela não duplica em sequência e que o índice único existe, mas duas
transações concorrentes de verdade precisariam de duas conexões (dblink),
e isso não foi montado.

`supabase/tests/confere.py` roda os testes e diz sozinho se toda recusa
esperada recusou e toda checagem `_ok` bateu — antes, a saída era lida a
olho. Os testes acharam **12 comportamentos** que divergiam do que a
migration ou este arquivo diziam (atividade exclusiva que não reconhecia
CIO com rooming, `jantar_grupo_obter` quebrada, convidado novo do Sympla
sem aviso de WhatsApp, helper de WhatsApp executável por `anon`, CIO com
reserva sem conseguir comprar quarto extra, faixa de quarto com 4 dígitos
cortada, funções sem escopo de staff por evento...). **Todos corrigidos
no mesmo dia** (`20261005090000` a `20261005140000`), a pedido do
organizador, e os testes afirmam o comportamento novo — lista com a
migration de cada um em `supabase/tests/LEIA-ME.md`. Essas 6 migrations
estão aplicadas e testadas no banco local; **ainda não foram pro
hospedado** (`supabase db push` é decisão do organizador — o projeto é o
mesmo do sistema de massagem em produção).

Daqui pra frente a regra é a de sempre: migration de comportamento nova
entra com teste no mesmo commit. O `23` olha o catálogo inteiro (função
exposta a anon, overload órfão, view sem security_invoker, tabela sem
RLS, função com `p_evento_slug` sem escopo) e pega sozinho quem esquecer
essas regras numa migration futura.

Conferido no hospedado, por consulta ao catálogo e por requisição real
com a chave anon (ver README §8), em 25/08/2026 — **não reconferido
desde então**:

- as 97 RPCs que as telas chamavam existiam, com os nomes de parâmetro
  batendo (hoje são bem mais de 97; a lista não foi atualizada)
- `anon` e `authenticated` não liam tabela nem view nenhuma do schema
- `anon` só executava `part_autocadastro`, `is_staff` e
  `meus_patrocinadores`
- zero achados de nível ERROR no `supabase db advisors`

**Como ficou o item "ninguém nunca clicou":** ao longo de 01–05/10/2026
Gerardo testou ao vivo contra o hospedado, logado de verdade — inclusive
um bug real de produção (`?evento=` ausente levando a um evento errado
silenciosamente, corrigido no mesmo dia). Dá pra considerar resolvido
na prática, mas nunca foi formalmente registrado como "sim, login por
magic link testado" — fica como um checklist informal, não uma prova
automatizada.

### Três armadilhas

1. **Nenhum papel lê tabela direto.** `anon` e `authenticated` só
   executam função. Um `.from("participantes")` numa tela do `gestao`
   morre com `permission denied` — o conserto é trocar por RPC, não
   devolver o grant. (As telas do sistema de massagem, em `/`, usam
   `.from()` no schema `public`; isso é outro schema e continua valendo.)
2. O projeto hospedado é o mesmo do sistema de massagem em produção. O
   `gestao` de lá tinha seguido outro caminho, e desde 24/08/2026 ele é
   a **origem**: `migrations/20260824110100_baseline_hospedado.sql` é o
   dump dele, e o fluxo é `db reset` no local, `db push` no hospedado.
   `supabase/remoto/` está encerrada e `supabase/migrations-antigas/`
   guarda a linhagem anterior, que não roda mais.
3. O site publica os **dois** sistemas (massagem em `/`, gestão em
   `/gestao/`). O deploy sai de `_site`, montado pelo
   `preparar-site.js` — publicar a raiz direto põe `.sql`, `.py` e
   `.md` em URL pública, como já aconteceu uma vez.
4. **`unaccent`/`pgcrypto` precisam estar instaladas no schema
   `public`, não num schema `extensions` separado**, se algum dia
   alguém tentar reconstruir o banco num Postgres puro (fora do CLI do
   Supabase) pra rodar migration ou teste. O baseline faz
   `SET search_path = 'public'` de propósito (comentário já explica o
   motivo do `unaccent('unaccent', ...)`) — instalar as extensões em
   outro schema faz esse `search_path` não as enxergar, e a primeira
   função que chama `unaccent` ou `gen_random_uuid()` quebra com "function
   does not exist", um erro que não tem nada a ver com a causa real.
   Achado replicando o histórico inteiro de migrations num Postgres
   local avulso em 05/10/2026, só pra validar `supabase/tests/12` antes
   de commitar.

### O CLI mente sobre o código de saída

`supabase db reset` e `db push` às vezes saem com **código 0 tendo
falhado** — a falha vem como JSON na saída. Leia a saída, não só o
código.

### O que depende do organizador, não de código

- as janelas das cotas e a largada (`eventos.escolha_abre_em`): a regra
  está no ar mas inerte enquanto os campos estiverem vazios
- dados reais de 2027 — hoje são 4 patrocinadores de ~61 e 8
  participantes de ~130, e `sympla_event_id` está vazio
- credenciais do `integracao.py` (Sympla, Autentique, Resend)
- domínio `ciocerrado.com.br` verificado no Resend (registros SPF/DKIM
  na Skymail) — sem isso, nenhum e-mail real sai da fila (ver "achados"
  acima)
- rodar `integracao.py --sympla --producao` de verdade pelo menos uma
  vez, pra confirmar que a importação automática da pesquisa de perfil
  (05/10) casa com os títulos reais das perguntas do formulário do
  Sympla — testado só com dado fictício até aqui
- confirmar que `supabase db push` está em dia no hospedado com as
  migrations mais recentes (a partir de `20261001230000`, quádruplo em
  diante) antes de testar as telas que dependem delas
