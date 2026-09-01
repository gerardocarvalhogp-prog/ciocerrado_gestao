# Modelo de dados — schema `gestao`

Documenta a estrutura do banco no nível de **o que cada coisa representa e quais
regras o banco garante** — não o DDL, que fica no próprio repositório de
migrações e envelhece se for copiado para cá.

Conferido por consulta direta ao banco hospedado (`information_schema`,
`pg_catalog`, `pg_policies`, corpo das funções via `pg_get_functiondef`) em
2026-09-01. Não é leitura do dump — é o schema como está rodando agora.

---

## Onde o sistema vive

- Supabase / Postgres.
- Schema **`gestao`**, dentro do mesmo projeto Supabase do sistema de
  agendamento de massagem.
- **36 tabelas**, 8 views, RLS ligada em todas as tabelas.

### Cuidado crítico com o schema `public`

O schema `public` do mesmo projeto pertence a **outro sistema** e contém tabelas
com nomes idênticos aos daqui: `eventos`, `participantes`, `reservas`, `admins`.

Foi exatamente essa colisão que motivou o schema próprio.

**Regra:** nenhuma query, view, função ou política do sistema de gestão pode ler
ou escrever no `public`. Toda referência é qualificada com `gestao.`. Qualquer
alteração que crie dependência entre os dois schemas é erro, não otimização.

---

## Tabelas

Agrupadas por área, não por ordem alfabética — a relação entre elas importa mais
que o nome.

### Evento e configuração

| Tabela | Representa |
|---|---|
| `eventos` | evento grande ou jantar. Eixo de quase toda consulta — quase toda outra tabela carrega `evento_id`. Tem `slug` único, usado na URL (`?evento=`). Status `rascunho` fica invisível ao público (ver RLS). |
| `etapas_config` | catálogo das etapas que entram no cálculo de pendência (`inscricao_aprovada`, `contrato_assinado`, `fatura_paga` etc.) — a chave que as views de pendência usam para rotular e ordenar. |
| `prazos_evento` | prazo por etapa, por evento — de onde vem o "atrasado" nas pendências. Tem `ativo`, então um prazo pode ser desligado sem apagar o histórico. |
| `precos` | valor por item cobrável (acompanhante, criança por faixa, transfer, quarto extra), por evento. |
| `segmentos` | lista fechada dos 14 segmentos de negócio (a mesma tabela e função `norm_segmento` documentadas em `[[gestao]]` para o cadastro de gestores). |

### Pessoas e empresas (base de contatos)

| Tabela | Representa |
|---|---|
| `gestores` | cadastro único de pessoas físicas (executivos), reaproveitado entre eventos — **não é um registro por evento**; a mesma pessoa mantém um só `gestores.id` na vida inteira do sistema. Tem trigger de normalização (maiúscula, UF válida — ver commit "Padrão de formatação no cadastro"). |
| `gestores_historico` | log de mudança de campo específico do gestor (ex.: troca de empresa vinda de importação, pendente de aprovação) — não é auditoria genérica, é o histórico de `sugestoes_ia` aplicadas. |
| `empresas` | cadastro de empresas, separado do texto livre `gestores.empresa`. Existe desde 25/08, mas só foi populada em massa em 31/08 (`admin_vincular_empresas`) — antes disso, 0 linhas. |
| `importacoes` | um registro por lote de planilha importada (`gestores`, `sympla`), com contagem de criados/atualizados/erros. Guarda o resultado, não os dados importados em si. |
| `sugestoes_ia` | fila de revisão humana para dado que a importação encontrou divergente (ex.: gestor mudou de empresa) — nada é aplicado sem aprovação nesta tabela. |
| `prospeccoes` | resultado da análise de aderência por IA (jantar ou sessão), pontuação e justificativa por empresa candidata — o rascunho antes de virar convite de verdade. |

### Patrocinador

| Tabela | Representa |
|---|---|
| `patrocinadores` | uma linha por empresa patrocinadora **por evento** (não é reaproveitado entre edições — `evento_id` é NOT NULL). `cota_id` define o nível. `natureza` distingue patrocinador comum de órgão público (ver `[[patrocinadores_natureza_check]]`). |
| `cotas` | nível de patrocínio por evento (Esmeralda, Diamante, Platina, Ouro, Prata — a ordem vem de `ordem_prioridade`), com os limites que a cota dá direito: `vagas_mesa_redonda`, `quartos_incluidos`. |
| `cota_quartos` | detalhamento de quantos quartos de cada tipo (duplo, triplo etc.) uma cota inclui — 1:N com `cotas`. |
| `usuarios_patrocinador` | login de acesso ao portal, vinculado a um `patrocinador_id`. **Múltiplos usuários por empresa** é modelado aqui — não há limite de linhas por `patrocinador_id`. `ativo` permite desativar acesso sem apagar o histórico. |
| `indicacoes` | executivo que o patrocinador indicou para ser convidado — fila de avaliação, não convite direto (ver RLS abaixo e `[[indicacoes_status_check]]` para os status possíveis). |
| `brindes` | brinde que o patrocinador vai distribuir, com `vai_enviar` (usado pela view de pendências) e rastreio de envio (`patro_informar_rastreio`). |

### Hospedagem

| Tabela | Representa |
|---|---|
| `quartos` | inventário físico de quartos por evento e tipo, com `status` (`disponivel` etc.) — a "capacidade" real do resort. |
| `categorias_quarto` | tipos de quarto configuráveis por evento (duplo, triplo, suíte...). |
| `reservas` | uma reserva de quarto, ligada a `participante_id` OU `patrocinador_id` (titular do quarto) e a `quarto_id`. `status` inclui `cancelado`, que é o padrão de "exclusão" usado nesta tabela — nada aqui é `DELETE`. |
| `ocupantes` | cada pessoa dentro de uma reserva: o titular, mais acompanhante(s) e filho(s), diferenciados por `tipo`. `categoria_cracha` decide o texto do crachá — inclusive `S/CRACHA` para menor de 21 (regra aplicada na view `v_etiquetas`, não em constraint). |

### Financeiro

| Tabela | Representa |
|---|---|
| `faturas` | fatura adicional do CIO (ou do patrocinador — tem as duas colunas de FK) por acompanhante/filho/noite extra. `status` inclui `estimada` (rascunho antes de emitir) e `cancelada`. |
| `fatura_itens` | linha discriminada de uma fatura (descrição, quantidade, valor unitário e total) — é daqui que vem o extrato item a item pedido em `30-area-cio.md`. |

### Contrato

| Tabela | Representa |
|---|---|
| `contratos` | um contrato por `participante_id` OU por `patrocinador_id` (`UNIQUE` nos dois — ver constraints). `status` espelha o Autentique; não há campo de "assinado manualmente fora do fluxo" visível no schema (ver *A confirmar*). |

### Mesa redonda e jantar

| Tabela | Representa |
|---|---|
| `sessoes` | uma sessão de convite por patrocinador — `tipo` distingue `mesa_redonda` de `jantar` (dentro do evento grande; jantar avulso usa a tabela `jantares` abaixo, separada). Guarda `escolha_liberada_em`/`escolha_encerrada_em`, que é o controle de janela de escolha do patrocinador. |
| `sessao_convidados` | convidado alocado numa sessão, com `status` de resposta (`confirmado` etc.) — é o que a view `v_pendencias_fatos` lê para "presença confirmada". |
| `jantares` | jantar avulso, **fora do modelo de evento grande** — não carrega `evento_id`. Um patrocinador por jantar (`patrocinador_nome` é texto livre, não FK — jantar não exige patrocinador já cadastrado no evento). Tem `sympla_url` próprio. |
| `jantar_convidados` | convidado de um jantar avulso, com funil de status próprio: `sugerido → convidado → confirmado → compareceu`, ou `recusado`. Documentado em detalhe em `50-jantares.md`. |

### Check-in e presença

| Tabela | Representa |
|---|---|
| `atividades` | atividade do evento grande (ex.: manhã, pós-almoço), por evento — a base do módulo "presença por atividade". |
| `checkins` | registro de chegada. Aceita `atividade_id NULL` (chegada geral ao evento) ou preenchido (presença numa atividade específica) — **é o mesmo modelo de tabela para os dois casos**, distinguidos pelo valor da coluna, não por tabelas separadas. Tem `desfeito_em` (desfazer sem apagar linha) e `registrado_por` (e-mail de quem bipou). |

### Integração e operação

| Tabela | Representa |
|---|---|
| `mapa_empresa_app` | de-para entre `empresa_id`/`patrocinador_id` internos e o identificador usado no app do evento do parceiro — a "chave de identificação estável" que `60-modulos-previstos.md` diz que falta acordar. A tabela **já existe**; ver seção de divergência. |
| `notificacoes` | fila de notificação/e-mail (Resend), por evento — corpo, tentativas, status. |
| `admins` | login de organizador e staff — role (`admin`/`staff`) e `ativo` na mesma tabela; não são tabelas separadas. |
| `admin_eventos` | associação de staff a evento — staff sem linha aqui não vê nenhum evento (ver RLS). Admin ignora esta tabela por completo. |
| `auditoria` | log genérico (tabela, registro, ação, campo, valor antigo/novo, usuário). **Só uma função grava nela hoje** (`admin_disparar_cobranca`) e a tabela está **vazia em produção** — existe o desenho, não a prática. Ver `DIVERGENCIAS.md`. |
| `participante_perfil` | dado de perfil complementar do participante (fora do núcleo de `gestores`) — *a confirmar exatamente quais campos e para que tela alimenta.* |

**Total: 36 tabelas** — a estimativa de "aproximadamente 25" do rascunho estava
desatualizada.

---

## Regras garantidas pelo banco — e as que não são

O rascunho listava seis regras como "garantidas pelo banco" sem dizer qual é
constraint e qual é validação de função. Conferido uma a uma:

| Regra | Onde vive |
|---|---|
| Um patrocinador só acessa linha da própria empresa | **Não é RLS na prática** — ver seção seguinte. É checagem dentro de cada função (`_exige_patrocinador` / `meus_patrocinadores()`). |
| Vagas de mesa redonda não excedem a cota | **Função**, não constraint. `patro_escolher_convidados` recusa com `'Cota de % vaga(s); voce ja tem % e tentou somar %'`. |
| Convidado não se repete na mesma mesa em dias diferentes | **Função**, não constraint. Mesma função, `'Convidado ja esta em outra sessao deste tipo'`. |
| Ocupação de quarto não excede a capacidade | **Função**, não constraint. `part_salvar_rooming`, `'O quarto comporta % pessoa(s)...'`. |
| Check-in duplicado não gera dois registros | **Função**, não constraint — não há `UNIQUE` em `checkins`. `checkin_registrar` faz `SELECT` antes do `INSERT` e devolve `ja_estava:true` em vez de duplicar. |
| Etapas inaplicáveis ao tipo de evento não existem como pendência | **View** (`v_pendencias_fatos`) — cada etapa só é gerada pela `UNION` correspondente (ex.: `hospedagem_preenchida` só existe para quem tem `reservas`). Jantar avulso (sem `evento_id`) não entra em nenhuma dessas uniões. |

**Nenhuma das seis é uma constraint de banco** (`CHECK`/`UNIQUE`/`EXCLUDE`). Isso
não as torna frágeis — como nenhum papel além de `service_role` tem `GRANT`
direto em tabela (ver seção seguinte), a função **é** o único caminho de
escrita, então a regra vale para toda API e toda tela. Mas vale para uma
importação em massa rodada como `service_role` ou uma migration futura, essas
regras não protegem — só a função protege.

O que **é** constraint de banco, confirmado: `UNIQUE` em `contratos.participante_id`
e `contratos.patrocinador_id` (um contrato por participante/patrocinador),
`UNIQUE` em `eventos.slug`, `UNIQUE` em `mapa_empresa_app` por
evento+empresa e por evento+patrocinador, e um `CHECK` de valores fechados
(enum-like) em praticamente toda coluna `status`/`origem`/`natureza`.

**Exclusão:** não há `DELETE` como estratégia visível. O padrão observado é
status (`cancelado`, `recusado`, `inativo`, `ativo=false`) — nenhuma tabela
teve `ON DELETE` de linha de negócio identificado nas funções lidas.

---

## Acesso e isolamento — o que a política realmente garante

**Achado central, que muda a leitura do resto desta seção:** nenhum papel de
cliente (`anon`, `authenticated`) tem `GRANT` de leitura ou escrita em
**nenhuma tabela nem view** do schema `gestao` — confirmado por
`information_schema.table_privileges` (zero linhas para esses dois papéis, em
36 tabelas + 8 views). Isso significa que as *policies* de RLS abaixo, embora
existam e estejam corretamente escritas, **não são o mecanismo operante para
quem usa o sistema pela tela** — sem `GRANT`, a policy nunca chega a ser
avaliada, porque a query nem sai do PostgREST. Todo acesso de verdade passa por
função `SECURITY DEFINER`, que roda com o privilégio de quem *definiu* a
função, não de quem chama.

Isso não é uma falha — é a mesma decisão que o `CLAUDE.md` do projeto já
registra ("nenhum papel lê tabela direto"). Mas muda a resposta de "em que
policy o isolamento se apoia": não é a policy de RLS, é a checagem dentro da
função.

### Como cada perfil é resolvido

| Perfil | Função-chave | Como identifica "quem sou eu" |
|---|---|---|
| Organizador (`admin`) | `is_admin()` / `_exige_admin()` | linha em `admins` com `role='admin'` e `ativo`, pelo e-mail do JWT |
| Staff | `is_staff()` / `_exige_staff()` | linha em `admins` com **qualquer role** e `ativo` — `admin` e `staff` são o mesmo mecanismo, distinguidos só pela coluna `role` |
| Patrocinador | `_exige_patrocinador(p_id)` → `pode_ver_patrocinador(p_id)` → `is_staff() OR p_id IN (meus_patrocinadores())` | `meus_patrocinadores()` lista **todos** os `patrocinador_id` em `usuarios_patrocinador` com o e-mail do JWT e `ativo` — um usuário pode estar ligado a mais de uma empresa, se houver mais de uma linha |
| CIO | `_meu_participante(p_evento_slug)` | uma linha em `participantes` cujo `gestores.email_norm` bate com o JWT, **dentro do evento do slug informado**, com `status <> 'cancelado'` |

**Staff tem bypass explícito em `pode_ver_patrocinador`** — `is_staff()` vem
primeiro no `OR`, então qualquer staff ativo enxerga qualquer patrocinador,
sem precisar de linha em `usuarios_patrocinador`. Isso é intencional (staff
opera para todos), mas significa que o alcance de staff sobre dado de
patrocinador **não é limitado por evento** — só o acesso a `eventos`/telas de
gestão é (via `admin_eventos`, ver abaixo). Vale confirmar se isso é a
intenção para o dado financeiro do patrocinador também.

### RLS que existe, ainda que hoje inatingível por client

Nas 36 tabelas, o padrão é: uma policy `ALL` para `is_staff()` (acesso total),
e, em **7 tabelas apenas** (`brindes`, `indicacoes`, `ocupantes`,
`patrocinadores`, `reservas`, `sessoes`, `usuarios_patrocinador`), uma segunda
policy de `SELECT` filtrando por `meus_patrocinadores()`. Nenhuma tabela tem
policy para papel "CIO" — o acesso do CIO é 100% via função, nunca via RLS de
tabela.

### Verificação de vazamento entre patrocinadores

Todas as **21 funções `patro_*`** chamadas por `portal.html` foram lidas.
19 chamam `_exige_patrocinador` explicitamente. As 2 exceções
(`patro_disponibilidade`, `patro_manual`) foram conferidas: devolvem dado
agregado do evento (quartos livres por tipo e preço; nome/local/prazos do
evento) — nenhuma das duas expõe dado de empresa. **Nenhuma rota de
contorno encontrada** nas funções client-facing do portal.

Não foi auditado, por estar fora do escopo desta passagem, se alguma **view**
(`v_esperados`, `v_painel_participantes` etc.) é chamada diretamente por algum
papel não-staff — como nenhum papel tem `GRANT` em view, isso não é alcançável
hoje, mas se um `GRANT` for adicionado no futuro sem revisar o
`security_invoker` de cada view, essa garantia muda. As 8 views existentes
**têm** `security_invoker=true` (rodam com o privilégio de quem consulta, não
do dono) — o ajuste correto para o dia em que algum `GRANT` for cogitado.

*A confirmar: alcance exato do staff sobre dado financeiro fora do próprio
evento associado; se o patrocinador enxerga eventos passados (não achei
filtro de "evento corrente" em `meus_patrocinadores`, que é evento-agnóstico
por desenho).*

---

## Views

8 views, todas com `security_invoker=true`, lidas por definição completa:

| View | Consolida |
|---|---|
| `v_esperados` | lista única de "quem deveria estar no evento" — junta ocupante de quarto, participante aprovado sem reserva, e usuário de patrocinador sem reserva, numa só lista com `pessoa_key` prefixada por tipo (`ocupante:`, `participante:`, `usuario_patro:`). Base do check-in. |
| `v_etiquetas` | mesma união de `v_esperados`, mas formatada para etiqueta/crachá: aplica a regra de menor de 21 sem crachá (`S/CRACHA`), resolve `apto`. |
| `v_checkins_resumo` | contagem de check-in por empresa patrocinadora, ignorando check-in desfeito (`desfeito_em IS NULL`). |
| `v_disponibilidade_quartos` | quartos livres por tipo, calculado por `NOT EXISTS` contra reserva não cancelada — é o que `patro_disponibilidade` expõe ao portal. |
| `v_ordem_escolha` | fila de prioridade de escolha do patrocinador (mesa redonda), por `ordem_prioridade` da cota e ordem de fechamento — base de "de quem é a vez". |
| `v_painel_participantes` | uma linha por participante com status de inscrição, contrato e rooming consolidados — parece ser a base do painel "Visão geral" do admin, *a confirmar contra `10-admin.md`*. |
| `v_pendencias_fatos` | uma linha por (evento, sujeito, etapa), com data de abertura e de conclusão — a base bruta do módulo de pendências. Cobre 8 etapas: inscrição aprovada, contrato assinado (participante e patrocinador), hospedagem preenchida, fatura paga, presença confirmada, convidados de mesa/jantar escolhidos, indicação de CIO feita, quartos preenchidos, brindes definidos. |
| `v_pendencias` | `v_pendencias_fatos` + `etapas_config` + `prazos_evento`, com `dias_em_aberto` e `nivel` (`ok`/`atencao`/`atrasado`) calculado contra o prazo. **Isto é o módulo de acompanhamento de pendências que `60-modulos-previstos.md` descreve como não construído** — ver `DIVERGENCIAS.md`. |

---

## A confirmar com o organizador / no schema

- `participante_perfil`: quais campos exatamente e qual tela os usa.
- Se `contratos` tem algum campo de sobrescrita manual para assinatura fora do
  fluxo do Autentique — não encontrado no schema; se existe, é fora da tabela.
- Alcance de staff sobre dado financeiro de patrocinador fora do evento
  associado a ele em `admin_eventos`.
- Se o patrocinador deveria ter acesso a eventos passados — hoje
  `meus_patrocinadores()` não filtra por evento nem por status.
- `auditoria` grava só em `admin_disparar_cobranca` e está vazia em produção:
  é para expandir, ou é vestigial de uma função que ainda não roda de verdade?
