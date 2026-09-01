# Divergências entre o rascunho e o código, e riscos encontrados

Apurado em 2026-09-01, conferindo os 11 arquivos de `docs/` contra o código-fonte
e o banco hospedado. Nada foi corrigido no sistema por esta tarefa — só
documentado ou registrado aqui, por instrução explícita do escopo.

Ordenado por peso: primeiro o que muda o entendimento do sistema, depois
correções pontuais.

---

## 1. Isolamento entre patrocinadores não é RLS — é função

**O rascunho (`70-modelo-de-dados.md` original) afirmava:** "O isolamento
entre patrocinadores é sustentado por RLS, não por filtro no front."

**O código mostra:** nenhum papel de cliente (`anon`, `authenticated`) tem
`GRANT` de leitura/escrita em nenhuma das 36 tabelas nem das 8 views do
schema. As *policies* de RLS existem e estão corretas, mas nunca chegam a ser
avaliadas — a query não sai do PostgREST sem `GRANT`. O isolamento de verdade
é feito função por função (`_exige_patrocinador` → `meus_patrocinadores()`).

**Por que importa:** quem for confiar no RLS como camada de segurança (por
exemplo, ao dar `GRANT` de leitura direta a alguma view no futuro, para um
relatório mais rápido) estaria assumindo uma proteção que hoje não é a que
está em vigor. As 8 views já têm `security_invoker=true`, o que é o ajuste
certo para esse dia — mas ninguém validou o comportamento delas com `GRANT`
concedido, porque isso nunca aconteceu.

**Risco, não corrigido:** nenhum — é descrição do estado atual, que já é
seguro. Registrado para não ser mal interpretado depois.

---

## 2. Três "módulos previstos" já estão em produção

**O rascunho (`60-modulos-previstos.md`) afirmava:** "Nada aqui existe na
interface", para os três módulos (pendências/cobrança, presença/QR/WhatsApp,
integração com o app do evento).

**O código mostra:** os dois primeiros estão construídos por inteiro, com
tela (abas Acompanhamento e Atividades em `admin.html`), e o terceiro está
parcialmente construído (Cenário A, dentro da aba Equipe). Só a fração
dependente de terceiro externo (Meta para WhatsApp, parceiro para API do
app) continua de fato bloqueada.

**Por que importa:** é a divergência mais séria da apuração — alguém lendo
só o rascunho concluiria que precisa **construir** essas telas, quando na
verdade elas já existem e só faltam ajustes ou dependem de terceiro. Detalhe
completo em `10-admin.md`, `40-checkin.md`, `80-integracoes.md` e
`60-modulos-previstos.md` (reescrito).

---

## 3. QR code no check-in: "previsto" que já está em produção

**O rascunho (`40-checkin.md`) afirmava:** "Previsto, não disponível... Hoje
o check-in é por busca de nome."

**O código mostra:** `checkin.html` já lê QR pela câmera do celular (`jsQR`),
com botão próprio, funcionando junto com a busca por nome — não é
substituição, é opção adicional.

---

## 4. Resend: o "modo seguro" não cobre o caminho que a tela usa

**O rascunho (`80-integracoes.md`) afirmava:** "Em desenvolvimento e em
teste: modo que monta a mensagem sem enviar."

**O código mostra dois caminhos com comportamento diferente:**
- `integracao.py` (script agendado): respeita `--producao`; sem a flag, só
  loga, não envia.
- Edge Function `enviar-notificacoes`, chamada pelo botão de e-mail em
  `admin.html`: **não tem gate de ambiente nenhum.** Toda chamada bem-sucedida
  dispara e-mail real.

**Risco real, não corrigido — já em efeito hoje:** qualquer staff/admin que
clicar em "Enviar teste" ou "Enviar toda a fila" no painel dispara envio real
pelo Resend, em qualquer ambiente, sem aviso de que não há gate de teste.
Hoje isso falha com 403 porque `ciocerrado.com.br` não está verificado no
Resend — mas assim que o domínio for verificado, o próximo clique em
"Enviar toda a fila" feito por engano (em teste, por curiosidade, por
qualquer staff) envia e-mail de verdade para participantes reais. Vale
avaliar se esse botão deveria ter uma confirmação mais forte, ou um ambiente
de teste separado — decisão do organizador, não corrigida aqui.

---

## 5. Autentique: não existe sandbox específico

**O rascunho afirmava:** "Em desenvolvimento, contrato roda em modo
sandbox."

**O código mostra:** não há sandbox exclusivo do Autentique. Existe um único
flag `--producao` no `integracao.py`, que trava **Sympla, Autentique e
Resend ao mesmo tempo** — não é uma trava por serviço, é uma trava do script
inteiro.

---

## 6. Autentique: consulta periódica, não webhook

**O rascunho perguntava:** "O retorno de assinatura é webhook ou consulta
periódica?"

**O código responde com certeza:** consulta periódica
(`integracao.py --status`). Não existe endpoint de webhook em nenhuma Edge
Function do repositório.

---

## 7. Sympla: dois caminhos de entrada, não um

**O rascunho perguntava:** "A entrada é por API ou por importação de
arquivo?"

**O código responde:** os dois coexistem — API via `integracao.py`
(agendado, fora da tela) e importação manual de arquivo pelo `admin.html`
(aba Cadastro). Não são alternativas, são caminhos complementares.

---

## 8. Regras "garantidas pelo banco" não são constraints

**O rascunho (`70-modelo-de-dados.md`) listava seis regras como "garantidas
pelo banco" sem dizer o mecanismo.**

**Conferido uma a uma:** nenhuma é `CHECK`/`UNIQUE`/`EXCLUDE`. Todas vivem
dentro de função `SECURITY DEFINER` (checagem explícita, com `raise
exception`). Isso não as torna frágeis, porque não há outro caminho de
escrita — mas uma importação em massa rodada como `service_role`, ou uma
migration futura que insira direto na tabela, não passaria por nenhuma
dessas checagens. Detalhe função a função em `70-modelo-de-dados.md`.

---

## 9. Contagem de tabelas e abas estava desatualizada

- `70-modelo-de-dados.md` original: "aproximadamente 25 tabelas". Real: **36
  tabelas, 8 views.**
- `10-admin.md` original: 6 seções nomeadas genericamente. Real: **17 abas**
  distintas — várias sem correspondência clara com os nomes do rascunho
  ("Logística" não existe como aba; virou Quartos + Organização + Etiquetas +
  Sessões + Atividades, entre outras).
- `20-portal-patrocinador.md` original: 5 abas. Real: **7** — faltavam
  Convidados e Manual.

---

## 10. Check-in/check-out com "noite extra" no CIO — não encontrado

**O rascunho (`30-area-cio.md`) descrevia:** CIO escolhe data de
entrada/saída no hotel; data fora do período do evento gera "noite extra"
com cobrança.

**O código não tem isso.** Não há campo de data de entrada/saída em
`rooming.html`, nem cálculo de noite extra em `part_previa_fatura` nem
`part_calcular_fatura`. Ou essa regra nunca foi construída como descrita, ou
existe por outro caminho não encontrado nesta apuração. Ver `PERGUNTAS.md`.

---

## 11. "Lista de validação sem nome" para o patrocinador — não encontrada

**O rascunho (`50-jantares.md`) descrevia** uma etapa em que o patrocinador
recebe só empresa/segmento/cidade/estado/aderência, sem nome de executivo,
antes do convite.

**Não encontrada em `jantares.html`.** A tela de staff mostra nome de
convidado em toda lista. Se essa validação acontece, é fora do sistema
(planilha, e-mail, ou pela skill `jantares-cio-cerrado`) — não há como
confirmar pelo código.

---

## 12. Trilha de auditoria: existe no schema, quase não é usada

A tabela `auditoria` tem um desenho completo (tabela, registro, ação, campo,
valor antigo/novo, usuário) mas **só uma função grava nela**
(`admin_disparar_cobranca`) e está **vazia em produção**. Não é bug — é
estado real que vale o organizador saber, para não presumir que existe uma
trilha de auditoria abrangente quando na prática ela cobre só um evento.

---

## 13. Divisão staff/admin é mais restrita do que o rascunho supunha

**O rascunho dizia:** "staff não deve conseguir alterar cadastro, cota,
valor ou alocação" — implicando que *ver* essas coisas seria permitido.

**O código mostra:** 81 das 111 funções `admin_*` exigem admin
especificamente — **inclusive para listar**, não só para alterar. Um staff
que abra as abas Cadastro, Estrutura, Patrocinadores, Preços, Financeiro ou
Pesquisa provavelmente recebe erro de acesso ao tentar carregar a lista, não
uma lista vazia ou resumida.

**Risco de UX, não corrigido:** a aba aparece para o staff (não há filtro de
aba no client), mas o conteúdo falha. Se isso é intencional, não há problema;
se não é, é uma tela quebrada para quem não deveria nem ver o botão. Decisão
do organizador — ver `PERGUNTAS.md`.

---

## 14. Itens levantados mas não fechados nesta apuração (não são divergência confirmada — ficaram como risco a olhar)

- **26 funções `admin_*`** cujo mecanismo de guarda não bateu com o padrão de
  busca (`_exige_admin`/`_exige_staff` como substring) usado nesta apuração.
  Podem usar outro mecanismo válido, ou merecer conferência função a função —
  não foi possível nesta passagem.
- **Portal do patrocinador não tem exportação própria** (nenhuma chamada de
  exportação encontrada em `portal.html`) — se isso é intencional (dado
  sensível não sai da tela) ou lacuna, não foi possível concluir só pelo
  código.
