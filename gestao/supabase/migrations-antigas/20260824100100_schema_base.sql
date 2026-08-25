-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- schema.sql  ·  parte 1 de N  ·  estrutura base
--
-- Padrao: Supabase/Postgres, RLS ligado em tudo, acesso por funcoes
-- SECURITY DEFINER (mesmo modelo do sistema de agendamento de massagem).
--
-- Ordem de execucao:
--   1) schema.sql        <- este arquivo (tabelas, indices, RLS, papeis)
--   2) funcoes-part.sql  (fluxo do participante)
--   3) funcoes-patro.sql (portal do patrocinador)
--   4) funcoes-admin.sql (operacao e relatorios)
--   5) seed.sql          (evento 2027 + cotas)
-- =====================================================================

-- ---------------------------------------------------------------------
-- IMPORTANTE: tudo vive no schema "gestao", isolado do sistema de
-- agendamento de massagem (que ocupa o schema public com tabelas de
-- mesmo nome: eventos, participantes, reservas, admins).
--
-- Extensoes ficam em public de proposito - sao compartilhadas.
-- ---------------------------------------------------------------------

create extension if not exists "pgcrypto";
create extension if not exists "unaccent";

-- ANTES DE RODAR: a primeira tentativa deste script (sem o schema
-- gestao) criou norm_doc/touch_updated_at em public e pode ter
-- sobrescrito a norm_doc do sistema de massagem. Confira:
--
--   select public.norm_doc('048.742.986-99');
--   -- esperado pelo sistema de massagem: 04874298699
--   -- se voltar com ponto e hifen, restaure a norm_doc do multievento.sql
--
-- Este arquivo nao mexe mais em public: tudo nasce em gestao.

create schema if not exists gestao;

-- Cria os objetos deste arquivo dentro de gestao. As funcoes helper
-- (norm_doc, norm_cpf) tambem nascem em gestao, entao a norm_doc do
-- sistema de massagem, que vive em public, fica intacta.
set search_path = gestao, public;

-- =====================================================================
-- 0. UTILITARIOS
-- =====================================================================

-- Normaliza e-mail para comparacao: minusculo, sem acento, sem espaco.
-- IMPORTANTE: usar unaccent com o dicionario explicito ('unaccent', v).
-- A forma de 1 argumento e STABLE, nao IMMUTABLE, e quebra o uso em
-- coluna GENERATED e em indice. A de 2 argumentos e immutable.
create or replace function norm_doc(v text)
returns text language sql immutable as $$
  select nullif(
    regexp_replace(lower(unaccent('unaccent', coalesce(v,''))), '[^a-z0-9@._+-]', '', 'g'),
    ''
  );
$$;

-- CPF/CNPJ: so digitos. Nao dava para reusar norm_doc porque ela
-- preserva ponto e hifen (necessarios no e-mail), e "048.742.986-99"
-- ficaria diferente de "04874298699".
create or replace function norm_cpf(v text)
returns text language sql immutable as $$
  select nullif(regexp_replace(coalesce(v,''), '[^0-9]', '', 'g'), '');
$$;

create or replace function touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- =====================================================================
-- 1. EVENTOS E CONTROLE DE ACESSO
-- =====================================================================

create table eventos (
  id              uuid primary key default gen_random_uuid(),
  slug            text unique not null,          -- ?evento=cerrado2027
  nome            text not null,
  local           text,
  data_inicio     date,
  data_fim        date,
  status          text not null default 'rascunho'
                  check (status in ('rascunho','aberto','encerrado')),
  -- prazos exibidos no manual do patrocinador
  prazo_contrato  date,
  prazo_rooming   date,
  prazo_cancelamento date,
  sympla_event_id text,
  created_at      timestamptz default now(),
  updated_at      timestamptz default now()
);
create trigger trg_eventos_upd before update on eventos
  for each row execute function touch_updated_at();

-- Papeis internos. 'admin' = tudo; 'staff' = operacao do dia (check-in,
-- etiquetas, alocacao de quarto) sem mexer em cadastro/financeiro.
create table admins (
  id         uuid primary key default gen_random_uuid(),
  email      text not null,
  -- comparacao sempre pelo normalizado dos DOIS lados: o e-mail digitado
  -- no cadastro vem como a pessoa escreveu, o do JWT vem do provedor.
  email_norm text generated always as (norm_doc(email)) stored,
  nome       text,
  role       text not null default 'staff' check (role in ('admin','staff')),
  ativo      boolean not null default true,
  created_at timestamptz default now()
);
create unique index admins_email_uk on admins(email_norm);

create or replace function is_admin()
returns boolean language sql stable security definer set search_path = gestao, public as $$
  select exists (
    select 1 from admins
    where email_norm = norm_doc(auth.jwt() ->> 'email')
      and role = 'admin' and ativo
  );
$$;

create or replace function is_staff()
returns boolean language sql stable security definer set search_path = gestao, public as $$
  select exists (
    select 1 from admins
    where email_norm = norm_doc(auth.jwt() ->> 'email')
      and ativo
  );
$$;

-- =====================================================================
-- 2. PARTICIPANTES (GESTORES / CIOs)
-- =====================================================================

-- Base mestre de gestores, independente de evento. E o cadastro que a
-- rotina de atualizacao em massa (com IA) mantem vivo entre as edicoes.
create table gestores (
  id            uuid primary key default gen_random_uuid(),
  nome          text not null,
  email         text not null,
  email_norm    text generated always as (norm_doc(email)) stored,
  cpf           text,
  cpf_norm      text generated always as (norm_cpf(cpf)) stored,
  telefone      text,
  cargo         text,
  empresa       text,
  cnpj          text,
  segmento      text,
  estado        text,
  perfil        text,                    -- CLIENTE, CIO, CONVIDADO...
  ativo         boolean not null default true,
  origem        text default 'manual'    -- manual | importacao | ia | autocadastro
                check (origem in ('manual','importacao','ia','autocadastro','indicacao')),
  created_at    timestamptz default now(),
  updated_at    timestamptz default now()
);
create unique index gestores_email_uk on gestores(email_norm);
create index gestores_empresa_ix on gestores(lower(empresa));
create trigger trg_gestores_upd before update on gestores
  for each row execute function touch_updated_at();

-- Historico de troca de empresa/cargo. E o que alimenta a deteccao de
-- "esse CIO mudou de empresa" na atualizacao em massa.
create table gestores_historico (
  id           uuid primary key default gen_random_uuid(),
  gestor_id    uuid not null references gestores(id) on delete cascade,
  campo        text not null,           -- empresa | cargo | email ...
  valor_antigo text,
  valor_novo   text,
  detectado_por text default 'manual',  -- manual | importacao | ia
  created_at   timestamptz default now()
);
create index gestores_hist_ix on gestores_historico(gestor_id, created_at desc);

-- Participacao de um gestor em UM evento (o que era "inscrito").
create table participantes (
  id             uuid primary key default gen_random_uuid(),
  evento_id      uuid not null references eventos(id) on delete cascade,
  gestor_id      uuid not null references gestores(id) on delete restrict,
  sympla_id      text,
  tipo_ingresso  text,
  status         text not null default 'pendente'
                 check (status in ('pendente','aprovado','recusado','cancelado')),
  origem         text not null default 'sympla'
                 check (origem in ('sympla','autocadastro','indicacao','manual')),
  indicado_por_patrocinador_id uuid,     -- FK adicionada apos patrocinadores
  aprovado_em    timestamptz,
  aprovado_por   text,
  created_at     timestamptz default now(),
  updated_at     timestamptz default now()
);
create unique index participantes_uk on participantes(evento_id, gestor_id);
create index participantes_status_ix on participantes(evento_id, status);
create trigger trg_participantes_upd before update on participantes
  for each row execute function touch_updated_at();

-- Respostas da pesquisa de perfil (o export "Lista de participantes").
-- Guardado em jsonb porque o questionario muda a cada edicao.
create table participante_perfil (
  participante_id uuid primary key references participantes(id) on delete cascade,
  faturamento     text,
  orcamento_ti    text,
  colaboradores   text,
  colaboradores_ti text,
  erp_atual       text,
  respostas       jsonb not null default '{}'::jsonb,  -- demais campos
  consentimento_lgpd boolean,
  updated_at      timestamptz default now()
);

-- =====================================================================
-- 3. CONTRATOS (AUTENTIQUE)
-- =====================================================================

create table contratos (
  id                uuid primary key default gen_random_uuid(),
  participante_id   uuid not null unique references participantes(id) on delete cascade,
  autentique_id     text,
  autentique_url    text,
  status            text not null default 'nao_enviado'
                    check (status in ('nao_enviado','enviado','assinado','recusado','cancelado')),
  enviado_em        timestamptz,
  assinado_em       timestamptz,
  lembretes_enviados int not null default 0,
  ultimo_lembrete_em timestamptz,
  updated_at        timestamptz default now()
);
create index contratos_status_ix on contratos(status);
create trigger trg_contratos_upd before update on contratos
  for each row execute function touch_updated_at();

-- =====================================================================
-- 4. PATROCINADORES, COTAS E USUARIOS
-- =====================================================================

-- Nivel de cota + o que ele da direito. A ordem_prioridade e o que
-- define quem escolhe primeiro na mesa redonda (1 = escolhe primeiro).
create table cotas (
  id                 uuid primary key default gen_random_uuid(),
  evento_id          uuid not null references eventos(id) on delete cascade,
  nome               text not null,        -- Esmeralda, Diamante, Platina...
  ordem_prioridade   int  not null,        -- 1 = Esmeralda
  quartos_incluidos  int  not null default 0,
  tipo_quarto_padrao text not null default 'duplo'
                     check (tipo_quarto_padrao in ('single','duplo','triplo')),
  vagas_mesa_redonda int  not null default 0,
  tem_reuniao_exclusiva boolean not null default false,
  tem_jantar         boolean not null default false,
  created_at         timestamptz default now()
);
create unique index cotas_uk on cotas(evento_id, nome);

create table patrocinadores (
  id             uuid primary key default gen_random_uuid(),
  evento_id      uuid not null references eventos(id) on delete cascade,
  cota_id        uuid references cotas(id) on delete set null,
  empresa        text not null,
  cnpj           text,
  segmento       text,
  o_que_vende    text,          -- texto livre; alimenta o match de jantar
  logo_url       text,
  -- excecoes por patrocinador (ex.: QI Network com vaga extra na mesa)
  quartos_extras_cota int not null default 0,
  vagas_mesa_override int,
  status         text not null default 'ativo'
                 check (status in ('ativo','inativo')),
  -- carimbo de "fechou" = contrato + rooming completos. Desempata a
  -- ordem de escolha DENTRO da mesma cota.
  fechado_em     timestamptz,
  created_at     timestamptz default now(),
  updated_at     timestamptz default now()
);
create unique index patrocinadores_uk on patrocinadores(evento_id, lower(empresa));
create trigger trg_patrocinadores_upd before update on patrocinadores
  for each row execute function touch_updated_at();

alter table participantes
  add constraint participantes_indicador_fk
  foreign key (indicado_por_patrocinador_id)
  references patrocinadores(id) on delete set null;

-- N usuarios por patrocinador. Todos veem o mesmo painel da empresa.
create table usuarios_patrocinador (
  id               uuid primary key default gen_random_uuid(),
  patrocinador_id  uuid not null references patrocinadores(id) on delete cascade,
  email            text not null,
  email_norm       text generated always as (norm_doc(email)) stored,
  nome             text,
  telefone         text,
  ativo            boolean not null default true,
  created_at       timestamptz default now()
);
create unique index usuarios_patro_uk on usuarios_patrocinador(patrocinador_id, email_norm);
create index usuarios_patro_email_ix on usuarios_patrocinador(email_norm);

-- Patrocinadores do usuario logado (pode ser mais de um, na pratica e 1).
create or replace function meus_patrocinadores()
returns setof uuid language sql stable security definer set search_path = gestao, public as $$
  select patrocinador_id from usuarios_patrocinador
  where email_norm = norm_doc(auth.jwt() ->> 'email') and ativo;
$$;

create or replace function pode_ver_patrocinador(p_id uuid)
returns boolean language sql stable security definer set search_path = gestao, public as $$
  select is_staff() or p_id in (select meus_patrocinadores());
$$;

-- =====================================================================
-- 5. QUARTOS, RESERVAS E OCUPANTES
-- =====================================================================

-- Inventario real do hotel. O numero do quarto so e preenchido quando o
-- resort libera o espelho; ate la a reserva existe sem numero.
create table quartos (
  id          uuid primary key default gen_random_uuid(),
  evento_id   uuid not null references eventos(id) on delete cascade,
  numero      text,                  -- "214" (pode ser null ate a alocacao)
  tipo        text not null check (tipo in ('single','duplo','triplo')),
  capacidade  int  not null,
  bloco       text,
  status      text not null default 'disponivel'
              check (status in ('disponivel','reservado','bloqueado')),
  created_at  timestamptz default now()
);
create unique index quartos_uk on quartos(evento_id, numero) where numero is not null;
create index quartos_disp_ix on quartos(evento_id, tipo, status);

-- Reserva = um quarto atribuido a um participante OU a um patrocinador.
create table reservas (
  id               uuid primary key default gen_random_uuid(),
  evento_id        uuid not null references eventos(id) on delete cascade,
  quarto_id        uuid references quartos(id) on delete set null,
  participante_id  uuid references participantes(id) on delete cascade,
  patrocinador_id  uuid references patrocinadores(id) on delete cascade,
  rotulo           text,             -- "Quarto 1", "Quarto 2" no portal
  tipo             text not null check (tipo in ('single','duplo','triplo')),
  origem           text not null default 'cota'
                   check (origem in ('cota','inscricao','extra')),
  usa_transfer     boolean,
  transfer_origem  text,             -- GYN | BSB
  status           text not null default 'rascunho'
                   check (status in ('rascunho','completo','cancelado')),
  created_at       timestamptz default now(),
  updated_at       timestamptz default now(),
  -- pertence a um participante ou a um patrocinador, nunca aos dois
  constraint reservas_dono_ck check (
    (participante_id is not null and patrocinador_id is null) or
    (participante_id is null and patrocinador_id is not null)
  )
);
create index reservas_patro_ix on reservas(patrocinador_id);
create index reservas_part_ix  on reservas(participante_id);
create index reservas_quarto_ix on reservas(quarto_id);
create trigger trg_reservas_upd before update on reservas
  for each row execute function touch_updated_at();

-- Pessoas dentro da reserva: o proprio CIO, acompanhante, filho, ou a
-- equipe do patrocinador. A idade define a regra de cracha (<21 = s/ cracha).
create table ocupantes (
  id            uuid primary key default gen_random_uuid(),
  reserva_id    uuid not null references reservas(id) on delete cascade,
  nome          text not null,
  cpf           text,
  data_nascimento date,
  tipo          text not null default 'adulto'
                check (tipo in ('titular','adulto','crianca')),
  categoria_cracha text,             -- PROTAGONISTA | ACOMPANHANTE | PATROCINADOR | S/CRACHA
  usa_transfer  boolean,
  email         text,
  telefone      text,
  created_at    timestamptz default now(),
  updated_at    timestamptz default now()
);
create index ocupantes_reserva_ix on ocupantes(reserva_id);
create trigger trg_ocupantes_upd before update on ocupantes
  for each row execute function touch_updated_at();

-- Brinde do patrocinador para o quarto/hotel.
create table brindes (
  id              uuid primary key default gen_random_uuid(),
  patrocinador_id uuid not null references patrocinadores(id) on delete cascade,
  reserva_id      uuid references reservas(id) on delete cascade,
  vai_enviar      boolean not null default false,
  descricao       text,
  quantidade      int,
  observacao      text,
  created_at      timestamptz default now(),
  updated_at      timestamptz default now()
);
create trigger trg_brindes_upd before update on brindes
  for each row execute function touch_updated_at();

-- =====================================================================
-- 6. FINANCEIRO
-- =====================================================================

-- Tabela de precos por evento (acompanhante, crianca, transfer, quarto extra).
create table precos (
  id         uuid primary key default gen_random_uuid(),
  evento_id  uuid not null references eventos(id) on delete cascade,
  item       text not null,   -- acompanhante_adulto | crianca | transfer | quarto_single...
  descricao  text,
  valor      numeric(12,2) not null default 0,
  created_at timestamptz default now()
);
create unique index precos_uk on precos(evento_id, item);

create table faturas (
  id               uuid primary key default gen_random_uuid(),
  evento_id        uuid not null references eventos(id) on delete cascade,
  participante_id  uuid references participantes(id) on delete cascade,
  patrocinador_id  uuid references patrocinadores(id) on delete cascade,
  total            numeric(12,2) not null default 0,
  status           text not null default 'estimada'
                   check (status in ('estimada','emitida','paga','cancelada')),
  emitida_em       timestamptz,
  paga_em          timestamptz,
  created_at       timestamptz default now(),
  updated_at       timestamptz default now()
);
create trigger trg_faturas_upd before update on faturas
  for each row execute function touch_updated_at();

create table fatura_itens (
  id          uuid primary key default gen_random_uuid(),
  fatura_id   uuid not null references faturas(id) on delete cascade,
  reserva_id  uuid references reservas(id) on delete set null,
  descricao   text not null,
  quantidade  int not null default 1,
  valor_unit  numeric(12,2) not null default 0,
  valor_total numeric(12,2) generated always as (quantidade * valor_unit) stored
);
create index fatura_itens_ix on fatura_itens(fatura_id);

-- =====================================================================
-- 7. INDICACOES, MESA REDONDA E JANTARES
-- =====================================================================

-- Patrocinador indicando um CIO para o evento.
create table indicacoes (
  id              uuid primary key default gen_random_uuid(),
  evento_id       uuid not null references eventos(id) on delete cascade,
  patrocinador_id uuid not null references patrocinadores(id) on delete cascade,
  nome            text not null,
  empresa         text,
  cargo           text,
  email           text,
  telefone        text,
  observacao      text,
  status          text not null default 'nova'
                  check (status in ('nova','convidado','inscrito','recusado','duplicado')),
  gestor_id       uuid references gestores(id) on delete set null,
  created_at      timestamptz default now(),
  updated_at      timestamptz default now()
);
create index indicacoes_patro_ix on indicacoes(patrocinador_id);
create trigger trg_indicacoes_upd before update on indicacoes
  for each row execute function touch_updated_at();

-- Sessoes de mesa redonda / reuniao exclusiva.
create table sessoes (
  id              uuid primary key default gen_random_uuid(),
  evento_id       uuid not null references eventos(id) on delete cascade,
  patrocinador_id uuid not null references patrocinadores(id) on delete cascade,
  tipo            text not null default 'mesa_redonda'
                  check (tipo in ('mesa_redonda','reuniao_exclusiva','jantar')),
  data            date,
  horario         time,
  local           text,
  vagas           int not null default 0,
  -- janela de escolha: abre por ordem de cota e, dentro da cota, por
  -- quem fechou primeiro (ver funcao abrir_rodada_escolha)
  escolha_liberada_em  timestamptz,
  escolha_encerrada_em timestamptz,
  created_at      timestamptz default now()
);
create index sessoes_evento_ix on sessoes(evento_id, tipo);

create table sessao_convidados (
  id              uuid primary key default gen_random_uuid(),
  sessao_id       uuid not null references sessoes(id) on delete cascade,
  participante_id uuid not null references participantes(id) on delete cascade,
  origem          text not null default 'patrocinador'
                  check (origem in ('patrocinador','admin','match')),
  aderencia       numeric(5,2),     -- % do match, quando veio do motor
  status          text not null default 'confirmado'
                  check (status in ('confirmado','removido')),
  created_at      timestamptz default now()
);
-- mesmo convidado nao repete na mesma sessao
create unique index sessao_conv_uk on sessao_convidados(sessao_id, participante_id)
  where status = 'confirmado';
-- e nao repete no mesmo patrocinador em dias diferentes: checado em funcao

-- =====================================================================
-- 8. CHECK-IN E ETIQUETAS
-- =====================================================================

create table checkins (
  id              uuid primary key default gen_random_uuid(),
  evento_id       uuid not null references eventos(id) on delete cascade,
  patrocinador_id uuid references patrocinadores(id) on delete set null,
  ocupante_id     uuid references ocupantes(id) on delete set null,
  nome            text not null,
  email           text,
  local           text,             -- lounge, credenciamento, palestra...
  registrado_em   timestamptz not null default now(),
  registrado_por  text
);
create index checkins_patro_ix on checkins(evento_id, patrocinador_id);
create index checkins_data_ix  on checkins(evento_id, registrado_em);

-- =====================================================================
-- 9. IMPORTACAO EM MASSA E SUGESTOES DA IA
-- =====================================================================

create table importacoes (
  id            uuid primary key default gen_random_uuid(),
  evento_id     uuid references eventos(id) on delete set null,
  tipo          text not null,      -- gestores | slots | patrocinadores | quartos
  arquivo       text,
  total_linhas  int default 0,
  criados       int default 0,
  atualizados   int default 0,
  erros         int default 0,
  executado_por text,
  created_at    timestamptz default now()
);

-- Fila de sugestoes geradas pela IA. Nada e aplicado sem aprovacao.
create table sugestoes_ia (
  id            uuid primary key default gen_random_uuid(),
  tipo          text not null
                check (tipo in ('troca_empresa','novo_gestor','nova_empresa','dado_divergente')),
  gestor_id     uuid references gestores(id) on delete cascade,
  empresa       text,
  campo         text,
  valor_atual   text,
  valor_sugerido text,
  confianca     numeric(5,2),
  fonte         text,               -- de onde a IA tirou (planilha, web, sympla)
  justificativa text,
  status        text not null default 'pendente'
                check (status in ('pendente','aprovada','ignorada','aplicada')),
  revisado_por  text,
  revisado_em   timestamptz,
  created_at    timestamptz default now()
);
create index sugestoes_status_ix on sugestoes_ia(status, tipo);

-- =====================================================================
-- 10. NOTIFICACOES E AUDITORIA
-- =====================================================================

create table notificacoes (
  id              uuid primary key default gen_random_uuid(),
  evento_id       uuid references eventos(id) on delete cascade,
  destinatario    text not null,
  tipo            text not null,    -- contrato_enviado | contrato_lembrete |
                                    -- rooming_ok | fatura_gerada | mesa_liberada...
  assunto         text,
  status          text not null default 'enfileirada'
                  check (status in ('enfileirada','enviada','erro')),
  erro            text,
  enviada_em      timestamptz,
  created_at      timestamptz default now()
);
create index notificacoes_ix on notificacoes(status, tipo);

create table auditoria (
  id            uuid primary key default gen_random_uuid(),
  tabela        text not null,
  registro_id   uuid,
  acao          text not null,      -- insert | update | delete
  campo         text,
  valor_antigo  text,
  valor_novo    text,
  usuario       text,
  created_at    timestamptz default now()
);
create index auditoria_ix on auditoria(tabela, registro_id, created_at desc);

-- =====================================================================
-- 11. RLS
-- Regra geral: nada e lido direto pelo cliente. Tudo passa por funcao
-- SECURITY DEFINER. As policies abaixo sao a rede de seguranca.
-- =====================================================================

alter table eventos               enable row level security;
alter table admins                enable row level security;
alter table gestores              enable row level security;
alter table gestores_historico    enable row level security;
alter table participantes         enable row level security;
alter table participante_perfil   enable row level security;
alter table contratos             enable row level security;
alter table cotas                 enable row level security;
alter table patrocinadores        enable row level security;
alter table usuarios_patrocinador enable row level security;
alter table quartos               enable row level security;
alter table reservas              enable row level security;
alter table ocupantes             enable row level security;
alter table brindes               enable row level security;
alter table precos                enable row level security;
alter table faturas               enable row level security;
alter table fatura_itens          enable row level security;
alter table indicacoes            enable row level security;
alter table sessoes               enable row level security;
alter table sessao_convidados     enable row level security;
alter table checkins              enable row level security;
alter table importacoes           enable row level security;
alter table sugestoes_ia          enable row level security;
alter table notificacoes          enable row level security;
alter table auditoria             enable row level security;

-- Evento aberto e publico (o front precisa saber nome/datas/branding).
create policy eventos_read_pub on eventos
  for select using (status <> 'rascunho' or is_staff());

-- Staff enxerga tudo nas tabelas operacionais.
do $$
declare t text;
begin
  foreach t in array array[
    'gestores','gestores_historico','participantes','participante_perfil',
    'contratos','cotas','patrocinadores','usuarios_patrocinador','quartos',
    'reservas','ocupantes','brindes','precos','faturas','fatura_itens',
    'indicacoes','sessoes','sessao_convidados','checkins','importacoes',
    'sugestoes_ia','notificacoes','auditoria','admins','eventos'
  ] loop
    execute format(
      'create policy %I_staff_all on %I for all using (is_staff()) with check (is_staff())',
      t, t);
  end loop;
end $$;

-- Patrocinador enxerga a propria empresa (leitura).
create policy patro_self_read on patrocinadores
  for select using (id in (select meus_patrocinadores()));

create policy patro_usuarios_read on usuarios_patrocinador
  for select using (patrocinador_id in (select meus_patrocinadores()));

create policy patro_reservas_read on reservas
  for select using (patrocinador_id in (select meus_patrocinadores()));

create policy patro_ocupantes_read on ocupantes
  for select using (
    reserva_id in (select id from reservas
                   where patrocinador_id in (select meus_patrocinadores()))
  );

create policy patro_brindes_read on brindes
  for select using (patrocinador_id in (select meus_patrocinadores()));

create policy patro_indicacoes_read on indicacoes
  for select using (patrocinador_id in (select meus_patrocinadores()));

create policy patro_sessoes_read on sessoes
  for select using (patrocinador_id in (select meus_patrocinadores()));

-- =====================================================================
-- 12. VIEWS DE APOIO
-- =====================================================================

-- Disponibilidade de quartos por tipo (usada na compra de quarto extra).
create or replace view v_disponibilidade_quartos as
select
  q.evento_id,
  q.tipo,
  count(*) filter (where q.status = 'disponivel'
                     and not exists (select 1 from reservas r
                                     where r.quarto_id = q.id
                                       and r.status <> 'cancelado')) as livres,
  count(*) as total
from quartos q
group by q.evento_id, q.tipo;

-- Base das etiquetas: uma linha por pessoa com quarto e categoria.
-- Regra de cracha: menores de 21 anos ficam sem cracha.
create or replace view v_etiquetas as
select
  r.evento_id,
  q.numero                              as apto,
  o.nome,
  coalesce(p.empresa, g.empresa)        as empresa,
  case
    when o.data_nascimento is not null
     and age(o.data_nascimento) < interval '21 years' then 'S/CRACHA'
    else coalesce(o.categoria_cracha,
                  case when r.patrocinador_id is not null then 'PATROCINADOR'
                       when o.tipo = 'titular' then 'PROTAGONISTA'
                       else 'ACOMPANHANTE' end)
  end                                   as categoria
from ocupantes o
join reservas r        on r.id = o.reserva_id and r.status <> 'cancelado'
left join quartos q    on q.id = r.quarto_id
left join patrocinadores p on p.id = r.patrocinador_id
left join participantes pa on pa.id = r.participante_id
left join gestores g   on g.id = pa.gestor_id;

-- Ordem de escolha da mesa redonda: cota mais alta primeiro; dentro da
-- cota, quem fechou (contrato + rooming) primeiro. Quem nao fechou vai
-- para o fim da fila da propria cota.
create or replace view v_ordem_escolha as
select
  p.evento_id,
  p.id                    as patrocinador_id,
  p.empresa,
  c.nome                  as cota,
  c.ordem_prioridade,
  p.fechado_em,
  row_number() over (
    partition by p.evento_id
    order by c.ordem_prioridade asc,
             p.fechado_em asc nulls last,
             p.created_at asc
  ) as posicao
from patrocinadores p
join cotas c on c.id = p.cota_id
where p.status = 'ativo';

-- Painel do admin: status de cada participante numa linha so.
create or replace view v_painel_participantes as
select
  pa.evento_id,
  pa.id                   as participante_id,
  g.nome,
  g.empresa,
  g.email,
  pa.status               as status_inscricao,
  coalesce(ct.status,'nao_enviado') as status_contrato,
  case
    when r.id is null then 'nao_iniciado'
    when r.status = 'completo' then 'completo'
    else 'parcial'
  end                     as status_rooming,
  r.usa_transfer,
  q.numero                as quarto
from participantes pa
join gestores g          on g.id = pa.gestor_id
left join contratos ct   on ct.participante_id = pa.id
left join reservas r     on r.participante_id = pa.id and r.status <> 'cancelado'
left join quartos q      on q.id = r.quarto_id;

-- Resumo de check-ins por patrocinador (mesmo formato do relatorio atual).
create or replace view v_checkins_resumo as
select
  c.evento_id,
  p.empresa,
  count(*) as total_checkins
from checkins c
join patrocinadores p on p.id = c.patrocinador_id
group by c.evento_id, p.empresa
order by p.empresa;


-- =====================================================================
-- 13. EXPOSICAO DO SCHEMA NA API
-- Sem isto o supabase-js nao enxerga nada em gestao.
-- =====================================================================

grant usage on schema gestao to anon, authenticated, service_role;
grant all on all tables    in schema gestao to anon, authenticated, service_role;
grant all on all sequences in schema gestao to anon, authenticated, service_role;
grant all on all functions in schema gestao to anon, authenticated, service_role;

alter default privileges in schema gestao
  grant all on tables to anon, authenticated, service_role;
alter default privileges in schema gestao
  grant all on functions to anon, authenticated, service_role;

-- FALTA UM PASSO NO PAINEL (nao da para fazer por SQL):
--   Supabase > Settings > API > Exposed schemas
--   adicionar "gestao" ao lado de "public".
-- No cliente, use:  supabase.schema('gestao').rpc(...)
