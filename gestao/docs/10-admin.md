# Painel do organizador e do staff — `admin.html`

Tela central do sistema, com **17 abas**, não 6 — o rascunho agrupava várias
telas reais sob nomes genéricos ("Logística", "Divulgação") que não
correspondem a abas de fato.

Abas reais: **Painel, Acompanhamento, Aprovações, Cadastro, Quartos,
Organização, Etiquetas, Brindes, Sessões, Atividades, Relatórios, Financeiro,
Estrutura, Patrocinadores, Pesquisa, Prospecção, Preços, Equipe.**

O **evento ativo é selecionado no cabeçalho** e condiciona quase todas as
abas — a maioria dos RPCs recebe `p_evento_slug`.

---

## Achado central: divisão real entre organizador e staff

**O rascunho perguntava a divisão exata de permissões — o código responde com
precisão.** Nenhuma aba é escondida do staff no client (não há checagem de
papel escondendo botão de aba em `admin.html`); a restrição é 100% do lado do
servidor, função por função.

Contadas as 111 funções `admin_*`: **81 exigem `_exige_admin()`** (só
organizador — inclusive **listar** dados, não só alterar: `admin_listar_gestores`,
`admin_listar_cotas`, `admin_listar_patrocinadores`, `admin_listar_precos`,
`admin_listar_empresas`, `admin_financeiro_resumo` são todas admin-only). Só
**4** aceitam staff também. As **26 restantes** não bateram com o padrão de
busca desta apuração (podem usar outro mecanismo de guarda, ou merecem
conferência — ver `PERGUNTAS.md`).

**Consequência prática, não confirmada pela tela (só pelo código):** um staff
que clique em Cadastro, Estrutura, Patrocinadores, Preços, Financeiro ou
Pesquisa provavelmente recebe erro "Acesso restrito a administradores" ao
tentar carregar a lista — a aba aparece, mas o conteúdo não. Isso pode ser
intencional (staff realmente não deveria nem ver essas listas) ou pode ser uma
aba que aparece quebrada para quem não deveria acessá-la. Ver
`DIVERGENCIAS.md`.

---

## Abas

### Painel

Entrada. *Não lido em profundidade nesta passagem — confirmar indicadores
exatos e se são clicáveis.*

### Acompanhamento

**Isto é o módulo de "pendências e cobrança" que `60-modulos-previstos.md`
descreve como não construído — e não é uma view solta, é uma aba completa e
funcional.** Movido para cá — ver `60-modulos-previstos.md` para o antes/depois.

- Resumo por etapa × público (CIO/patrocinador), contagem em dia / atenção /
  atrasado (`admin_pendencias_resumo`).
- Lista filtrável por nível, público e etapa (`admin_pendencias_lista`).
- **Configurar prazos**: por etapa, dias para "atenção" e para "atrasado",
  liga/desliga a etapa por evento (`admin_listar_prazos`,
  `admin_salvar_prazo`, `admin_gerar_prazos_padrao`).
- **Preparar cobrança**: abre modal com destinatário(s), assunto e corpo
  pré-preenchidos (`admin_preparar_cobranca`), avisa se já foi cobrado nos
  últimos 3 dias, e só envia com clique explícito em "Enviar agora"
  (`admin_disparar_cobranca`) — **decisão humana, exatamente como o desenho
  original exigia.** Sem "cobrar todos": um envio por vez, por pessoa.
- `admin_disparar_cobranca` é a única função do schema que grava em
  `auditoria` — ver `70-modelo-de-dados.md`.

### Aprovações

Separada de Cadastro. Duas listas: inscrições pendentes de aprovação
(`admin_listar_pendentes`, `admin_aprovar_participante`) e indicações de CIO
feitas por patrocinador, aguardando virar convite
(`admin_listar_indicacoes`, `admin_converter_indicacao`).

### Cadastro

Base única de gestores (pessoas), reaproveitada entre eventos — ver
`70-modelo-de-dados.md`. Import de planilha, import de inscritos do Sympla,
fila de sugestões da IA para revisão (troca de empresa detectada em
importação), CRUD de empresas, grid de gestores com filtro multi-seleção.
Documentado em detalhe nas migrations de agosto — não repetido aqui.

### Quartos

"Separar quartos" — alocação física de quarto por pessoa
(`admin_alocar_quarto`, `admin_listar_alocacao`, `admin_quartos_livres`). Tela
de operação, distinta de `Estrutura` (que cadastra o inventário) e distinta
de `Organização` (que é o quarto da própria equipe, não de convidado — ver
abaixo).

### Organização

**Não estava no rascunho, e não é o que o nome sugere.** É o quarto/hospedagem
da **equipe do CIO Cerrado** (staff, organizadores), fora da cota de nenhum
patrocinador — `admin_listar_quartos_equipe`, `admin_salvar_quarto_equipe`,
`admin_salvar_ocupantes_equipe`. Título genérico, escopo específico; vale
renomear a aba ou pelo menos documentar o real propósito, para não confundir
com "estrutura organizacional".

### Etiquetas

Geração de etiqueta/crachá a partir da lista consolidada (`admin_etiquetas` —
provavelmente sobre `v_etiquetas`, ver `70-modelo-de-dados.md`).

### Brindes

Visão do organizador sobre os brindes que cada patrocinador informou
(`admin_brindes_resumo`, `admin_listar_brindes`, `admin_marcar_brinde` — dá
para o organizador confirmar recebimento/entrega). `admin_gerar_sessoes`
aparece nesta aba também — *a confirmar se é atalho para gerar sessão de mesa
redonda a partir daqui, ou item não relacionado a brinde.*

### Sessões

"Mesas e jantares" — visão do organizador sobre as sessões de mesa redonda e
jantar por patrocinador: convidados confirmados, sugestões por aderência,
mailing (`admin_listar_sessoes`, `admin_convidados_sessao`,
`admin_adicionar_convidado_sessao`, `admin_remover_convidado_sessao`,
`admin_mailing_sessao`, `admin_match_jantar`). Ponto de contato entre a lógica
de mesa redonda do evento grande e `jantares.html` (que é módulo separado —
`admin_match_jantar` sugere alguma ponte entre os dois; *a confirmar o que
exatamente essa função faz.*).

### Atividades

**Isto é o módulo de "presença por atividade" que `60-modulos-previstos.md`
descreve como não construído — também já tem aba própria.** Cadastro de
atividade por evento (`admin_salvar_atividade`, `admin_remover_atividade`,
`admin_definir_usa_atividades` — liga/desliga o recurso por evento) e check-in
específico por atividade (`atividade_checkin_listar`,
`atividade_checkin_registrar`, reaproveitando `checkin_desfazer`). Ver
`60-modulos-previstos.md` para o que ainda falta (QR com contexto trocável —
ver `40-checkin.md`).

### Relatórios

Mailing list e pesquisa de perfil. **Nenhuma chamada de função encontrada
nesta faixa do código** — pode reaproveitar dados já carregados por outras
abas, ou exportar client-side sem RPC própria. *A confirmar.*

### Financeiro

Resumo financeiro do evento, itens de fatura, marcar fatura como
paga/emitida/cancelada, recalcular (`admin_financeiro_resumo`,
`admin_fatura_itens`, `admin_marcar_fatura`, `admin_recalcular_faturas`).

**Responde à pergunta represada do rascunho:** o Financeiro **registra e
gerencia status** — quem **dispara cobrança por e-mail** é a aba
Acompanhamento (`admin_disparar_cobranca`), não esta. As duas telas são
etapas diferentes do mesmo problema.

### Estrutura

"Estrutura do evento" — cadastro do evento em si (datas, prazos), cotas por
evento, patrocinadores por cota, inventário de quartos e categorias do
resort. É a configuração de base que todo o resto do painel depende
(`admin_salvar_evento`, `admin_salvar_cota`, `admin_definir_patrocinadores_cota`,
`admin_salvar_categoria_quarto`, `admin_criar_faixa_quartos`,
`admin_alterar_tipo_quartos`, `admin_importar_mapa_quartos`).

### Patrocinadores

CRUD de empresa patrocinadora e de seus usuários de acesso
(`admin_salvar_patrocinador`, `admin_salvar_usuario_patro`,
`admin_remover_usuario_patro`), geração de quartos da cota
(`admin_gerar_quartos_todos`) e enriquecimento por IA
(`admin_enriquecer_patrocinador` — provavelmente a mesma pesquisa web usada em
`jantares.html` para prospecção, aplicada ao cadastro do patrocinador).

**Responde a uma pergunta represada de `20-portal-patrocinador.md`:** é aqui,
não no portal, que um segundo usuário de acesso da empresa é criado.

### Pesquisa

**Não estava no rascunho.** "Pesquisa de perfil" — importação de respostas de
formulário e leitura por área de investimento
(`admin_importar_pesquisa`, `admin_pesquisa_areas`, `admin_pesquisa_por_area`,
`admin_pesquisa_resumo`). Módulo inteiro fora do que os 11 arquivos
originais previam — natureza exata *a confirmar com o organizador.*

### Prospecção

Curadoria de convidados para mesa redonda/rodada, no nível do evento grande —
irmã da Sondagem de `jantares.html`, mas escopo diferente ("rodadas" com
histórico de quem já foi convidado, para não repetir —
`admin_empresas_da_rodada`, `admin_listar_rodadas`, `admin_prospeccao_base`,
`admin_salvar_prospeccao`).

### Preços

Tabela de preço por item cobrável (acompanhante, criança, transfer, quarto
extra), por evento — a fonte que `part_previa_fatura`/`part_calcular_fatura`
consultam (ver `30-area-cio.md`).

### Equipe

Três funções empacotadas numa aba só:

1. **Gestão de acesso** — quem é admin/staff, e a quais eventos cada staff
   está associado (`admin_listar_equipe`, `admin_salvar_membro`,
   `admin_remover_membro`, `admin_definir_eventos_membro`,
   `admin_listar_eventos_membro`) — staff sem evento associado não vê nenhum
   (ver `70-modelo-de-dados.md`, tabela `admin_eventos`).
2. **Fila de e-mail** — visão dos envios pendentes/com erro
   (`admin_notificacoes_resumo`, `admin_notificacoes_com_erro`,
   `admin_notificacao_teste`).
3. **App do evento** — o de-para de ID (`mapa_empresa_app`) e exportação dos
   arquivos no formato do parceiro (`admin_definir_id_app_evento`,
   `admin_listar_mapa_empresas_app`, `admin_salvar_mapa_empresa_app`,
   `admin_exportar_empresas_app`, `admin_exportar_usuarios_app`). **Isto é o
   "Cenário A" de `60-modulos-previstos.md` — já construído, embutido aqui,
   não visível como aba própria.**

---

## Exportações

Confirmadas nesta apuração: gestores (Cadastro), etiquetas (Etiquetas e
Etiquetas de `jantares.html`), empresas e usuários no formato do app do
evento (Equipe → App do evento). *Lista completa e formato exato de cada uma
— não conferido arquivo a arquivo nesta passagem; exige abrir cada exportação
gerada, não só ler o código que a gera.*

---

## A confirmar com o organizador

- As 26 funções `admin_*` cujo mecanismo de guarda não bateu com
  `_exige_admin`/`_exige_staff` no grep desta apuração — conferir uma a uma.
- Se a experiência real do staff ao clicar numa aba admin-only é um erro
  visível, ou algo tratado com mais cuidado na tela.
- Escopo exato de `admin_match_jantar` — ponte entre Sessões e o módulo
  `jantares.html`?
- Natureza e origem do módulo Pesquisa de perfil — de onde vêm as respostas
  importadas (Sympla, formulário próprio, outro)?
- Indicadores exatos do Painel (Visão geral) e se são clicáveis.
- Lista completa de exportações e formato de cada uma.
