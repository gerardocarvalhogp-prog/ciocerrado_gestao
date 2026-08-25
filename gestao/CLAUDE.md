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
8 migrations.**

- [x] Banco, funções e RLS
- [x] Front: portal do patrocinador, rooming, admin, check-in, jantares
- [x] **Uma linhagem só** — o `db reset` local reproduz o hospedado
      coluna a coluna, função a função, política a política
- [x] Publicado em `https://ciocerrado.netlify.app/gestao/`
- [x] Rastreio de brindes, da promessa até a entrega no quarto
- [ ] Pagamento da fatura, webhook do Autentique, espelho de quartos do resort

### O que está verificado e o que não está

Conferido no banco local (`supabase db reset` + `supabase/tests/`):

- o baseline sobe do zero e o resultado bate com o hospedado
- os seis arquivos de teste exercitam portal, rooming, fila da mesa
  redonda, fatura, reserva com janela e brindes — trocando de papel com
  `request.jwt.claims`, como o PostgREST faz
- fatura complementar cobra a diferença, é idempotente no recálculo e
  vira crédito quando alguém sai depois de pagar
- a reserva da indicação resiste de baixo para cima: o indicado pela
  Ouro não aparece para a Esmeralda

Conferido no hospedado, por consulta ao catálogo e por requisição real
com a chave anon (ver README §7):

- as 97 RPCs que as telas chamam existem, com os nomes de parâmetro
  batendo
- `anon` e `authenticated` não leem tabela nem view nenhuma do schema
- `anon` só executa `part_autocadastro`, `is_staff` e
  `meus_patrocinadores`
- zero achados de nível ERROR no `supabase db advisors`

**Não** verificado: as telas rodando contra o hospedado com um usuário
de verdade, logado por magic link. Tudo foi medido no Postgres e pela
API — ninguém nunca clicou.

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
- um teste de ponta a ponta com login de verdade
