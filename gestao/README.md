# Sistema de Gestão · CIO Cerrado

Gestão de inscrição, contrato, rooming, cotas de patrocinador,
mesas redondas, jantares, check-in e relatórios.

Vive no schema `gestao` do Supabase, isolado do sistema de agendamento
de massagem que ocupa o `public`.

---

## 1. Banco — rodar nesta ordem

No SQL Editor do Supabase, um arquivo por vez:

| # | Arquivo | O que traz |
|---|---------|-----------|
| 1 | `schema.sql` | 25 tabelas, RLS, views |
| 2 | `schema-extra.sql` | `sessoes.passou_em` e `checkins.desfeito_em` — colunas que os passos 11–20 leem e nenhum deles cria |
| 3 | `funcoes-base-helpers.sql` | `_exige_admin`, `_exige_staff`, `_exige_patrocinador`, `_meu_participante` |
| 4 | `funcoes-patro.sql` | portal do patrocinador |
| 5 | `funcoes-part.sql` | fluxo do participante |
| 6 | `funcoes-admin.sql` | operação do evento |
| 7 | `funcoes-admin-listas.sql` | relatórios paginados |
| 8 | `funcoes-admin-config.sql` | equipe |
| 9 | `funcoes-admin-cadastros.sql` | evento, cotas, patrocinadores, usuários, quartos |
| 10 | `funcoes-checkin.sql` | desfazer check-in |
| 11 | `funcoes-pesquisa.sql` | pesquisa de perfil (importação e análise) |
| 12 | `migracao-02.sql` | cota única, composição de quartos, patrocinador enriquecido |
| 13 | `funcoes-prospeccao.sql` | prospecção de convidados para jantares |
| 14 | `funcoes-etiquetas.sql` | etiquetas com e sem hospedagem |
| 15 | `funcoes-financeiro.sql` | valores extras, cobrança e recebimento |
| 16 | `migracao-03.sql` | preço por faixa etária |
| 17 | `correcoes-01.sql` | bugs do relatório de QA (ambiguidade de coluna, importação, match) |
| 18 | `migracao-04.sql` | prospecção completa (posição do gestor, abrangência, 1º/2º executivo) |
| 19 | `migracao-05.sql` | convidado avulso em jantares + check-in de quem não está na lista |
| 20 | `migracao-06.sql` | módulo de jantares separado do evento |
| 21 | `seed.sql` | primeiro admin, evento em rascunho, cotas e preços em zero |

**A ordem 4–10 antes de 11–20 não é decorativa.** Os arquivos 11–20 são
patches incrementais que redefinem 47 funções também presentes em 4–10 —
entre elas as correções do QA de 18/08. Como no Postgres a última
definição vence, inverter a ordem reverteria essas correções sem erro
nenhum na tela.

Os passos 2 e 3 existem porque os arquivos-base originais se perderam: a
cadeia 11–20 chama quatro helpers `_exige_*`/`_meu_participante` e lê
duas colunas que nenhum arquivo presente cria. Sem eles, os `CREATE`
passam e a primeira chamada quebra em tempo de execução.

Depois, no painel do Supabase: **Settings → Data API → Settings →
Exposed schemas** e acrescente `gestao` ao lado de `public`.
Sem isso o `supabase-js` não enxerga nada.

Confira se funcionou:

```sql
select count(*) from gestao.eventos;
```

---

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

Publique os quatro juntos no Netlify.

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

## 7. O que ainda não existe

- Pagamento da fatura (hoje o valor é calculado e comunicado, não cobrado)
- Webhook do Autentique — o status é lido por polling, não em tempo real
- Importação do espelho de quartos do resort (hoje é por faixa de numeração)
- Envio dos brindes com rastreio
