# Sistema de Gestão · CIO Cerrado

Gestão de inscrição, contrato, rooming, cotas de patrocinador,
mesas redondas, jantares, check-in e relatórios.

Vive no schema `gestao` do Supabase, isolado do sistema de agendamento
de massagem que ocupa o `public`.

---

## 1. Banco — migrations

O banco vive em `supabase/migrations/`, versionado. **Não cole SQL no
painel.**

```bash
supabase db reset    # reconstrói o banco local do zero
supabase db push     # aplica no hospedado o que ainda não foi
```

O `db reset` é o teste de verdade: se a migration não sobe do zero, o
erro aparece aqui e não em produção. Repare que o CLI às vezes **sai com
código 0 mesmo tendo falhado** — a falha vem como JSON na saída. Leia a
saída, não só o código.

### O baseline

`20260824110100_baseline_hospedado.sql` é o dump do schema `gestao` do
projeto hospedado, tirado em 24/08/2026. Ele é a origem: reproduz banco,
funções, views, RLS e permissões exatamente como estão no ar.

Antes disso havia **duas** implementações do mesmo sistema — as
migrations escritas à mão e o hospedado, montado direto no SQL Editor.
As duas expunham a mesma API, mas por dentro divergiam: 33 funções
locais chamavam helpers (`exigir_admin`, `evento_id_por_slug`,
`cap_tipo`) que o hospedado nem tem. Cada correção precisava ser escrita
duas vezes, e o `db reset` testava um sistema que não era o que estava
publicado.

A linhagem antiga está em `supabase/migrations-antigas/`, fora do
caminho do CLI. Não roda mais; fica pelos cabeçalhos, que explicam
decisão por decisão como cada parte chegou onde chegou.

**Não edite o baseline.** Mudança entra como migration nova, depois
dele. A única linha do arquivo que não veio do `pg_dump` está marcada
como tal: ela repõe o `search_path`, que o dump zera — sem isso a
criação de `admins` quebra, porque a coluna gerada `email_norm` chama
`norm_doc`, que chama `unaccent` sem qualificar.

### O projeto hospedado é compartilhado

É **o mesmo projeto do sistema de agendamento de massagem**, que está em
produção no schema `public`. O `gestao` é isolado, mas o `db push` fala
com o projeto inteiro: leia o que vai subir antes de subir.

### Expor o schema

No projeto hospedado, uma vez: **Settings → Data API → Exposed schemas**,
acrescente `gestao` ao lado de `public`. Sem isso o `supabase-js` não
enxerga nada. No local isso já vem do `config.toml` (`[api] schemas`).

Confira se funcionou:

```sql
select count(*) from gestao.eventos;
```

## 2. Telas

Antes de publicar, preencha no topo de **cada** arquivo `.html`:

```js
const SUPABASE_URL  = "https://SEU-PROJETO.supabase.co";
const SUPABASE_ANON = "COLE_AQUI_A_CHAVE_ANON";
```

| Arquivo | Quem usa | Link |
|---------|----------|------|
| `rooming.html` | CIO / participante | `/rooming.html?evento=cerrado2027` |
| `portal.html` | patrocinador | `/portal.html?evento=cerrado2027` |
| `admin.html` | organização | `/admin.html?evento=cerrado2027` |
| `checkin.html` | equipe no resort | `/checkin.html?evento=cerrado2027` |
| `jantares.html` | organização | `/jantares.html` (sem evento — módulo próprio) |

Publique as cinco juntas no Netlify, **da pasta de cima** (a raiz serve
também o agendamento de massagem, em `/`):

```bash
node preparar-site.js                  # monta o _site
netlify deploy --dir=_site             # preview
netlify deploy --dir=_site --prod      # producao
```

O `preparar-site.js` copia só o que é web e está versionado. Publicar a
raiz direto colocaria `schema.sql`, as migrations, o `CLAUDE.md` e o
`integracao.py` em URL pública — foi o que aconteceu no deploy de
24/08/2026 e o que esse passo evita.

O `checkin.html` aceita `&local=Lounge` para registrar onde o check-in
aconteceu — útil para ter um link por posto.

---

## 3. Ordem de uso na primeira vez

1. Entrar no `admin.html` com seu e-mail
2. **Estrutura** — conferir o evento, as cotas e criar as faixas de quartos
3. **Patrocinadores** — cadastrar as empresas e os usuários de cada uma
4. Botão **Gerar quartos das cotas** — cria as reservas que o patrocinador vai preencher
5. **Preços** — valores de acompanhante, criança e transfer
6. **Equipe** — quem mais acessa, e com qual perfil
7. **Mesas e jantares** — criar as sessões

Sem o passo 4 o patrocinador entra no portal e vê "sua cota ainda não
tem quartos liberados".

---

## 4. Edge Function de IA

O enriquecimento de patrocinadores e a pontuação da prospecção chamam o
Claude. A chave **não pode** ficar no `admin.html`, que é público —
então a chamada passa por uma Edge Function.

```bash
supabase functions deploy ia
supabase secrets set ANTHROPIC_API_KEY=sk-ant-...
```

A função exige `is_admin()`: sem isso, qualquer pessoa com a chave anon
(que está no HTML publicado) usaria a conta da Anthropic à vontade.

Sem essa etapa, o painel funciona normalmente — só os botões
**Buscar dados** e **Analisar** (prospecção) é que falham.

---

## 5. Integrações

`integracao.py` roda fora do banco, no Agendador de Tarefas — mesmo
lugar do `rotina_cerrado.py`.

### Variáveis de ambiente

```
SUPABASE_URL=https://seu-projeto.supabase.co
SUPABASE_SERVICE_KEY=...        # service_role, não a anon
SYMPLA_TOKEN=...
AUTENTIQUE_TOKEN=...
AUTENTIQUE_TEMPLATE_ID=...      # documento modelo do contrato
RESEND_API_KEY=...
CERRADO_EVENTO=cerrado2027
CERRADO_REMETENTE=contato@ciocerrado.com.br
CERRADO_SITE=https://ciocerrado.netlify.app
```

A `service_role` ignora RLS de propósito — é processo de servidor.
**Nunca** coloque essa chave em arquivo `.html`.

### Comandos

```bash
python integracao.py --tudo                # modo seguro, não envia nada
python integracao.py --tudo --producao     # envia de verdade

python integracao.py --sympla --producao      # só sincroniza inscrições
python integracao.py --contratos --producao   # só envia contratos
python integracao.py --status --producao      # só lê assinaturas
python integracao.py --lembretes --producao   # só cobra quem não assinou
python integracao.py --emails --producao      # só despacha a fila
```

Rode primeiro **sem** `--producao`. Ele mostra tudo que faria sem tocar
em nada — vale conferir a lista antes do primeiro disparo real.

### Agendamento sugerido

- `--tudo --producao` a cada 2 horas no horário comercial
- `--emails --producao` a cada 15 minutos, se quiser e-mail mais rápido

O Sympla nunca aprova ninguém sozinho: inscrição nova entra como
`pendente` e espera decisão humana no painel.

---

## 6. Decisões que valem saber

**Portão do contrato.** O rooming só abre com inscrição aprovada *e*
contrato assinado. As duas condições são checadas no banco, não só na tela.

**Ordem da mesa redonda.** Cota mais alta escolhe primeiro
(`cotas.ordem_prioridade`); dentro da mesma cota, quem fechou contrato e
rooming antes. Quem não quer todas as vagas usa "passar a vez" e libera
a fila.

**Indicação no PERFIL é reserva, não sugestão.** Quem a empresa indicou
não aparece para nenhuma outra enquanto a cota dela estiver dentro da
janela. A vez passa para a cota seguinte quando a anterior termina de
escolher **ou** quando a janela vence — o que vier primeiro. Vencida sem
escolha, a reserva cai, o convidado volta para a lista geral e a empresa
fica **fora daquela sessão**: não escolhe nem quem sobrou.

**A janela é relativa, não uma data.** Cada cota tem `janela_horas`
("48h"), contadas do fim da cota anterior — o relógio anda no ritmo do
evento, e não de datas escolhidas no chute meses antes. A primeira cota
começa em `eventos.escolha_abre_em` (aba Estrutura, "Escolha das mesas
abre em"). Enquanto esse campo estiver vazio, **nada expira**: o relógio
só começa quando alguém diz que começou. Há um teto absoluto opcional por
cota (`prazo_indicacao`) para o caso de precisar de uma data-limite dura;
vale o que vier primeiro entre os três.

Cota sem mesa daquele tipo não segura a fila.

A reserva vale de baixo para cima também: o indicado pela Prata resiste
à Esmeralda. Se valesse só de cima para baixo não valeria nada, porque a
Esmeralda escolhe antes de todo mundo.

**Fatura recalculada do zero** a cada save, nunca acumulada. Fatura já
emitida ou paga não é tocada.

**Sugestões de IA nunca criam cadastro sozinhas.** Troca de empresa e
divergência de dado aplicam quando aprovadas, com rastro em
`gestores_historico`. Gestor e empresa novos ficam só sinalizados.

**Check-in desfeito não é apagado**, ganha `desfeito_em` — os relatórios
ignoram, mas a auditoria mantém.

**Preços fixos.** `acompanhante_adulto`, `crianca` e `transfer` são lidos
por nome no cálculo da fatura e não podem ser removidos. Para não
cobrar, deixe o valor em zero.

**Limite do Data API: 1000 linhas.** Todo relatório pagina. O detalhe de
check-ins é o caso crítico (≈130 por patrocinador × 61 empresas).

**Prospecção ≠ alocação.** A aba **Prospecção** escolhe quem convidar da
base ampla do CIO Cerrado (gente que ainda não está no evento) e gera a
lista de convites do Sympla. A aba **Mesas e jantares** distribui quem já
está inscrito. São dois momentos diferentes do mesmo processo.

**Histórico de convidados é automático.** A prospecção exclui empresas que
já participaram de jantar em qualquer edição, cruzando o banco — não
depende de marcar caixas.

**Cota única** é para evento sem hierarquia de patrocínio (jantar avulso):
sem fila de escolha, com uma cota criada automaticamente.

**Preço pode variar por faixa etária.** Cada item aceita várias faixas
(criança 0-5 cortesia, 6-11 meia, 12+ inteira). A idade considerada é a
do **início do evento**, não a de hoje — é assim que o resort cobra.
Faixas sobrepostas são rejeitadas: o preço ficaria ambíguo.

**Fatura só é recalculada no estado "estimada".** Emitida ou paga é
documento, não rascunho — o recálculo não a toca. Reabrir uma cobrança
paga apaga a data de pagamento, para a conferência não ficar com data
antiga em cobrança em aberto.

**Etiqueta funciona sem hospedagem.** Vem de três fontes: ocupantes de
quarto, participantes sem reserva e equipe de patrocinador sem quarto.

**Jantares são módulo separado, sem depender de evento.** Faz sentido
para os 40+ jantares avulsos por ano — cadastrar um não exige mais
passar pela estrutura inteira do Experience (cotas, quartos, contrato).
A base de gestores continua compartilhada, então o histórico de "já foi
convidado" funciona entre jantares avulsos e os do Experience, sem
depender de marcar caixinha na mão.

**A cota pode misturar tipos de quarto** — 2 duplos e 2 singles, por
exemplo. A geração das reservas respeita a composição.

---

## 7. Segurança

A chave `anon` está publicada dentro dos cinco `.html` — é assim que o
Supabase funciona. Por isso a pergunta que importa não é "quem tem a
chave", e sim "o que a chave abre".

### O que foi testado, em 24/08/2026

Com a chave anon e sem login nenhum, contra o projeto hospedado:

| alvo | resultado |
|---|---|
| as 29 tabelas via `/rest/v1/` | `[]` — RLS ligada nas 29, 37 políticas, nenhuma vale para `anon` |
| as 6 views via `/rest/v1/` | **vazavam** nome, empresa, apartamento e a fila de escolha |
| funções administrativas | `permission denied` — `anon` executa só `part_autocadastro`, `is_staff` e `meus_patrocinadores` |
| `service_role` / chaves de API nas páginas publicadas | nenhuma ocorrência |

O vazamento das views foi corrigido em
`20260824120000_fecha_views_para_anon.sql`: view no Postgres roda com o
dono, não com quem consulta, então a RLS das tabelas de baixo não era
aplicada. Agora as seis têm `security_invoker = true` e o `anon` perdeu
o acesso às tabelas do schema.

Também conferido, com consulta direta ao catálogo:

- as 108 funções `admin_/patro_/part_/checkin_/jantar_` checam papel na
  primeira linha; as quatro sem guarda ou são abertas por desenho
  (`part_autocadastro`), ou filtram por `meus_patrocinadores()`
  (`patro_meu_painel`), ou devolvem dado não sensível (`patro_manual`,
  `patro_disponibilidade`)
- nenhuma função `SECURITY DEFINER` está sem `search_path` fixo

### O que fica de recomendação

**`authenticated` ainda tem acesso de tabela.** Qualquer pessoa com um
magic link é `authenticated`, e as 29 tabelas estão abertas para esse
papel — sob RLS, que é escopada e foi conferida. Fechar também esse
acesso seria defesa em profundidade, já que as telas só falam por RPC
(não há um `.from(` nos cinco `.html`). Não fiz porque mexe no que já
funciona e pede um teste de tela antes.

**Proteção contra senha vazada, no Auth.** O painel do Supabase marca
como desligada. Vale pouco aqui, porque o login é por magic link e não
por senha, mas é um clique.

**`public.ibm_fila_convite`**, do sistema de massagem, também é uma view
sem `security_invoker`. Consultada como `anon`, voltou vazia — mas quem
cuida daquele sistema deveria olhar.

### Como repetir

```bash
supabase db advisors --linked --type security
```

## 8. O que ainda não existe

- Pagamento da fatura (hoje o valor é calculado e comunicado, não cobrado)
- Webhook do Autentique — o status é lido por polling, não em tempo real
- Importação do espelho de quartos do resort (hoje é por faixa de numeração)
- Envio dos brindes com rastreio
