# Integrações e ambiente

Nenhuma credencial, chave ou token neste arquivo. Cita-se o nome da variável de
ambiente, nunca o valor.

Conferido contra `integracao.py`, as Edge Functions (`supabase/functions/`) e
`admin.html` em 2026-09-01.

---

## Sympla — inscrição

Origem dos inscritos do evento. O sistema **consome**; não substitui o Sympla.

**Existem dois caminhos de entrada, não um:**

1. **API**, via `integracao.py --sympla` — chama
   `api.sympla.com.br/public/v3/events/{sympla_id}/participants` com o header
   `s_token`. Roda fora do banco e fora da tela, no Agendador de Tarefas do
   Windows (mesmo lugar de outro script de rotina do CIO Cerrado), autenticado
   como `service_role` — o script ignora RLS de propósito, por ser processo de
   servidor, não usuário. Frequência de execução: *a confirmar com o
   organizador* (não está no agendador deste repositório).
2. **Importação manual de arquivo**, pela aba Cadastro do `admin.html`
   ("Importar inscritos do Sympla") — sobe o `.xlsx` exportado à mão do painel
   do Sympla, para quando não se quer esperar o próximo ciclo do agendador.

Os dois convergem no mesmo destino: `gestores` + `participantes`, com
`status='pendente'`, `origem='sympla'` (via API) ou fluxo próprio da função de
importação (via arquivo).

- Inscrição entra como pendente de aprovação.
- Aprovação é do organizador. Antes dela, a pessoa não gera contrato, não ocupa
  quarto e não conta em cota.
- O export de participantes do Sympla traz faturamento anual, orçamento de TI,
  número de colaboradores, segmento e autorização de repasse de resultado
  analítico — são esses campos que sustentam a análise de porte usada em mesa
  redonda e curadoria de jantar.

**Gotcha conhecido:** o segmento é declarado pelo próprio inscrito e vem errado
com frequência (houve atacadista cadastrado como "Serviços Públicos"). Regra que
dependa de segmento precisa admitir exceção manual.

**Variáveis de ambiente:** `SYMPLA_TOKEN` (do lado do `integracao.py`; a
importação manual pela tela não usa token nenhum, o organizador já está
autenticado).

---

## Autentique — contrato

Geração e assinatura dos contratos, via `integracao.py`.

- API usada é **GraphQL** (`api.autentique.com.br/v2/graphql`), não REST.
- O status de assinatura no sistema é **reflexo** do Autentique — a leitura é
  **consulta periódica** (`integracao.py --status`, chama a API e atualiza
  `contratos.status`), **não webhook**. Não há endpoint de recebimento de
  webhook em nenhuma Edge Function do repositório.
- **Não existe um "modo sandbox" específico do Autentique no código** — o que
  existe é uma trava única e mais ampla, descrita abaixo.

**Correção ao rascunho:** não é um sandbox exclusivo do Autentique. O script
inteiro (`integracao.py`) roda em **modo seguro por padrão** — sem a flag
`--producao`, toda operação de efeito externo (Sympla, Autentique, e-mail) só
registra em log o que faria e não grava nada, não envia nada. `--producao` é
único e cobre as três integrações ao mesmo tempo, não uma trava por serviço.

**Regra:** nunca disparar contrato real a partir de ambiente de teste. É o erro
mais caro possível aqui — ele chega na caixa de um CIO.

**Variáveis de ambiente:** `AUTENTIQUE_TOKEN`, `AUTENTIQUE_TEMPLATE_ID` (id do
modelo de documento base no Autentique).

---

## Resend — e-mail

Envio transacional. **Dois caminhos distintos, com comportamento diferente em
desenvolvimento — divergência real, não nuance:**

1. **`integracao.py --emails`** (fila processada pelo script agendado): gated
   pelo mesmo `--producao` acima. Sem a flag, monta e loga, não envia.
2. **Edge Function `enviar-notificacoes`**, chamada ao vivo pelo botão "Enviar
   teste" / "Enviar toda a fila" em `admin.html`: **não tem gate de
   ambiente nenhum.** Chamada bem-sucedida dispara e-mail real pelo Resend,
   sempre — a única proteção é a exigência de estar autenticado como
   staff/admin (a função não usa `service_role`; repassa o token de quem
   chamou, e a RPC `notificacoes_pendentes` confere papel na primeira linha).

Ou seja: **"em desenvolvimento e em teste o Resend monta sem enviar" é
verdade só para o caminho 1.** Pela tela, o envio é real desde a primeira
chamada — confirmado em teste isolado nesta mesma apuração: a função recusou
enviar por 403 porque o domínio `ciocerrado.com.br` ainda não está verificado
no Resend (sem SPF/DKIM no DNS), não por estar em modo de teste.

**Nota de infraestrutura:** as caixas corporativas `@ciocerrado.com.br` ficam na
Skymail, não no Google Workspace, e a rede do escritório bloqueia portas SMTP de
saída em alguns momentos. Isso afeta scripts que enviam por SMTP direto — o
sistema, por usar API, não sofre com isso. Mas a falha de domínio não
verificado é silenciosa em outro sentido: o comentário no próprio código da
função alerta que, se o domínio não estivesse configurado de jeito nenhum (em
vez de "em verificação"), o Resend devolveria 200 e o e-mail simplesmente não
chegaria a lugar nenhum.

**Remetente:** `contato@ciocerrado.com.br`, fixo no código como padrão (variável
`REMETENTE`, sobrescrevível). Conta do Resend cadastrada no e-mail pessoal do
organizador.

**Variáveis de ambiente:** `RESEND_API_KEY` (as duas pontas usam a mesma
chave — `integracao.py` lê `RESEND_API_KEY` do ambiente do agendador; a Edge
Function lê o secret de mesmo nome configurado no Supabase), `REMETENTE`
(opcional, Edge Function).

---

## WhatsApp — API oficial

**Previsto, não disponível — mas o código de envio já existe**, em
`supabase/functions/enviar-whatsapp`, irmã de `enviar-notificacoes`. A própria
função recusa rodar e diz por quê, de propósito: falta (1) verificação da
conta no WhatsApp Business Platform, (2) número de telefone dedicado aprovado,
(3) pelo menos um template de mensagem aprovado pela Meta — fora da janela de
24h aberta pelo destinatário, toda mensagem **precisa** ser um template
pré-aprovado, não existe texto livre — e (4) opt-in explícito de quem recebe.

Nenhuma dessas quatro depende de código deste repositório. Enquanto não
existirem, a função é infraestrutura pronta e inerte — o rascunho descreve
isso corretamente como "previsto, não disponível", só faltava registrar que a
peça de código já está escrita e só espera a conta.

**Variáveis de ambiente (quando a conta existir):** `WHATSAPP_TOKEN`,
`WHATSAPP_PHONE_NUMBER_ID`.

---

## App do evento — integração por arquivo

**Parcialmente diferente do que o rascunho descreve.** O app do parceiro **não
tem API nenhuma hoje** — nem consulta, nem upsert (reenviar um e-mail já
existente é rejeitado, não atualizado) — só importação de planilha. Isso não é
uma limitação temporária do sistema de gestão; é uma limitação confirmada do
app do parceiro, registrada em levantamento próprio
(`03-analise-integracao-gestao-app.md`, `04-especificacao-parceiro.md` —
fora deste repositório de código).

**O que existe, construído (migration `20260831090000`, "Cenário A"):**
- `eventos.id_app`: o ID numérico do evento no admin do app, preenchido à mão
  (o app não expõe consulta desse número).
- tabela `mapa_empresa_app`: de-para entre `empresa_id`/`patrocinador_id`
  internos e o `empresa_id_app` numérico — também alimentado à mão, pela
  mesma razão.
- Com isso, o sistema **gera a planilha no formato exato que o app aceita**,
  já com o `empresa_id_app` certo por linha — a melhoria possível sem
  depender do parceiro.

**O que continua não existindo:** envio automático e retorno de dados do app
para o sistema (Cenário B/C). Isso segue dependendo de o parceiro construir
uma API — não há nada a fazer deste lado até isso ser acordado. Ver
`60-modulos-previstos.md`.

Regras do processo manual que continuam valendo:
- registros sem e-mail são excluídos da importação
- registros novos entram ao final do arquivo

---

## Supabase — banco e autenticação

- Banco no schema `gestao` (ver `70-modelo-de-dados.md`).
- Autenticação por **magic link**, com opção de criar senha — confirmado em
  código (login por senha e por link coexistem em todas as telas de usuário
  final).
- Isolamento entre patrocinadores **não é RLS na prática** — ver
  `70-modelo-de-dados.md`, seção "Acesso e isolamento": nenhum papel de
  cliente tem `GRANT` em tabela ou view; a garantia é dentro das funções
  `SECURITY DEFINER`.

*A confirmar: tempo de validade do magic link e da sessão — não é
parametrizado no schema `gestao`, é configuração de projeto do Supabase Auth,
fora do que este repositório versiona.*

---

## Netlify — publicação

Base publicada: `https://ciocerrado.netlify.app/gestao/`.

**Regra de desenvolvimento:** trabalho em branch separada, nunca direto em
produção. O deploy sai de uma pasta `_site` montada por script
(`preparar-site.js`) que escolhe só o que é público e está versionado — subir a
pasta raiz direto já publicou `.sql`/`.py`/`.md` por engano no passado.

*A confirmar: existe ambiente de preview/staging separado, ou o evento de teste
dentro da produção faz esse papel? Pelo Netlify CLI, `deploy` sem `--prod` gera
uma URL de preview temporária — *a confirmar se isso é usado como rotina.*

---

## A confirmar com o organizador

- Frequência real de execução do `integracao.py` no Agendador de Tarefas (não
  documentada no repositório de código).
- Onde ficam as variáveis de ambiente e quem tem acesso a elas — parte está no
  ambiente do Agendador de Tarefas (máquina local), parte em secrets do
  Supabase (Edge Functions); não há um único lugar.
- Rotina de backup do schema `gestao` e responsável por ela.
- Se o domínio `ciocerrado.com.br` já foi verificado no Resend (SPF/DKIM) —
  enquanto não estiver, o envio pela tela (`enviar-notificacoes`) continua
  falhando com 403 para qualquer destinatário fora da conta de testes.
