-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- funcoes-part.sql  ·  fluxo do participante (CIO)
--
-- Roda DEPOIS de schema.sql, schema-extra.sql e funcoes-patro.sql
-- (usa cap_tipo, evento_id_por_slug, preco_de e preco_por_idade).
--
-- Chamado por rooming.html.
-- =====================================================================

set search_path = gestao, public;

-- =====================================================================
-- 0. HELPERS
-- =====================================================================

-- Participante do usuario logado neste evento. Toda funcao part_* passa
-- por aqui: o e-mail vem do JWT, nunca de parametro, entao nao da para
-- pedir o rooming de outra pessoa trocando um id na chamada.
create or replace function meu_participante(p_evento_slug text)
returns uuid language sql stable security definer set search_path = gestao, public as $$
  select pa.id
  from participantes pa
  join gestores g on g.id = pa.gestor_id
  where pa.evento_id = evento_id_por_slug(p_evento_slug)
    and g.email_norm = norm_doc(auth.jwt() ->> 'email')
  limit 1;
$$;


-- =====================================================================
-- 1. AUTO-CADASTRO
--
-- Roda DESLOGADO (a tela de login oferece "ainda nao tenho cadastro"),
-- entao e a unica funcao deste arquivo aberta ao anon. Por isso ela nao
-- aprova ninguem: cria o participante como 'pendente' e para por ai. A
-- decisao e humana, no painel.
-- =====================================================================
create or replace function part_autocadastro(
  p_evento_slug text,
  p_nome text,
  p_email text,
  p_empresa text default null,
  p_cargo text default null,
  p_telefone text default null,
  p_cnpj text default null
)
returns jsonb
language plpgsql security definer set search_path = gestao, public as $$
declare
  v_evento uuid;
  v_status text;
  v_gestor uuid;
  v_part uuid;
begin
  if nullif(trim(coalesce(p_nome,'')),'') is null
     or nullif(trim(coalesce(p_email,'')),'') is null then
    raise exception 'Nome e e-mail sao obrigatorios.';
  end if;

  select id, status into v_evento, v_status from eventos where slug = p_evento_slug;
  if v_evento is null then
    raise exception 'Evento nao encontrado.';
  end if;
  if v_status <> 'aberto' then
    return jsonb_build_object('ok', false, 'motivo', 'evento_fechado');
  end if;

  select id into v_gestor from gestores where email_norm = norm_doc(p_email);

  if v_gestor is null then
    insert into gestores (nome, email, telefone, cargo, empresa, cnpj, origem)
    values (trim(p_nome), trim(p_email), p_telefone, p_cargo, p_empresa,
            p_cnpj, 'autocadastro')
    returning id into v_gestor;
  else
    -- nao sobrescreve cadastro existente com o que a pessoa digitou
    -- agora; so preenche o que estava vazio
    update gestores
       set telefone = coalesce(telefone, p_telefone),
           cargo    = coalesce(cargo,    p_cargo),
           empresa  = coalesce(empresa,  p_empresa),
           cnpj     = coalesce(cnpj,     p_cnpj)
     where id = v_gestor;
  end if;

  select id into v_part from participantes
  where evento_id = v_evento and gestor_id = v_gestor;

  if v_part is not null then
    return jsonb_build_object('ok', true, 'ja_inscrito', true);
  end if;

  insert into participantes (evento_id, gestor_id, status, origem)
  values (v_evento, v_gestor, 'pendente', 'autocadastro')
  returning id into v_part;

  insert into notificacoes (evento_id, destinatario, tipo, assunto)
  values (v_evento, trim(p_email), 'autocadastro_recebido',
          'Recebemos seu cadastro');

  return jsonb_build_object('ok', true, 'ja_inscrito', false, 'participante_id', v_part);
end;
$$;

-- =====================================================================
-- 2. STATUS
--
-- Uma chamada so devolve tudo que a trilha da tela precisa. O portao do
-- contrato (rooming_liberado) e decidido AQUI, no banco: a tela apenas
-- desenha o que recebe.
-- =====================================================================
create or replace function part_meu_status(p_evento_slug text)
returns jsonb
language plpgsql stable security definer set search_path = gestao, public as $$
declare
  v_part uuid;
  r record;
begin
  v_part := meu_participante(p_evento_slug);

  if v_part is null then
    return jsonb_build_object('inscrito', false);
  end if;

  select
    g.nome, g.empresa,
    pa.status as status_inscricao,
    coalesce(ct.status,'nao_enviado') as status_contrato,
    ct.autentique_url as contrato_url,
    e.prazo_contrato, e.prazo_rooming, e.prazo_cancelamento,
    case
      when res.id is null then 'nao_iniciado'
      when res.status = 'completo' then 'completo'
      else 'parcial'
    end as status_rooming
  into r
  from participantes pa
  join gestores g  on g.id = pa.gestor_id
  join eventos e   on e.id = pa.evento_id
  left join contratos ct on ct.participante_id = pa.id
  left join reservas res on res.participante_id = pa.id and res.status <> 'cancelado'
  where pa.id = v_part;

  return jsonb_build_object(
    'inscrito',          true,
    'participante_id',   v_part,
    'nome',              r.nome,
    'empresa',           r.empresa,
    'status_inscricao',  r.status_inscricao,
    'status_contrato',   r.status_contrato,
    'status_rooming',    r.status_rooming,
    'contrato_url',      r.contrato_url,
    'prazo_contrato',    r.prazo_contrato,
    'prazo_rooming',     r.prazo_rooming,
    'prazo_cancelamento',r.prazo_cancelamento,
    -- o portao: inscricao aprovada E contrato assinado
    'rooming_liberado',  (r.status_inscricao = 'aprovado'
                          and r.status_contrato = 'assinado')
  );
end;
$$;

-- =====================================================================
-- 3. ROOMING
-- =====================================================================

create or replace function part_listar_rooming(p_evento_slug text)
returns table (
  nome text, cpf text, data_nascimento date,
  tipo text, usa_transfer boolean
)
language plpgsql stable security definer set search_path = gestao, public as $$
declare v_part uuid;
begin
  v_part := meu_participante(p_evento_slug);
  if v_part is null then
    raise exception 'Nao encontramos sua inscricao neste evento.';
  end if;

  return query
  select o.nome, o.cpf, o.data_nascimento, o.tipo, coalesce(o.usa_transfer,false)
  from ocupantes o
  join reservas r on r.id = o.reserva_id
  where r.participante_id = v_part
    and r.status <> 'cancelado'
  order by (o.tipo = 'titular') desc, o.created_at;
end;
$$;


-- Confirma os dados de hospedagem.
--
-- Recebe a lista inteira de acompanhantes e substitui - a tela sempre
-- manda o estado completo. O titular e recriado aqui a partir do
-- cadastro, entao ele nunca some por engano.
create or replace function part_salvar_rooming(
  p_evento_slug text,
  p_acompanhantes jsonb default '[]'::jsonb,
  p_usa_transfer boolean default false,
  p_transfer_origem text default null
)
returns jsonb
language plpgsql security definer set search_path = gestao, public as $$
declare
  v_evento uuid;
  v_part uuid;
  v_res uuid;
  v_status jsonb;
  v_qtd int;
  v_tipo text;
  g record;
begin
  v_evento := evento_id_por_slug(p_evento_slug);
  v_part   := meu_participante(p_evento_slug);
  if v_part is null then
    raise exception 'Nao encontramos sua inscricao neste evento.';
  end if;

  -- portao do contrato, checado no banco e nao so na tela
  v_status := part_meu_status(p_evento_slug);
  if not (v_status->>'rooming_liberado')::boolean then
    raise exception 'O preenchimento abre depois da aprovacao da inscricao e da assinatura do contrato.';
  end if;

  if p_transfer_origem is not null and p_transfer_origem not in ('GYN','BSB') then
    raise exception 'Origem de transfer invalida.';
  end if;
  if coalesce(p_usa_transfer,false) and p_transfer_origem is null then
    raise exception 'Informe de onde sai o transfer.';
  end if;

  select count(*) into v_qtd
  from jsonb_array_elements(coalesce(p_acompanhantes,'[]'::jsonb)) o
  where nullif(trim(coalesce(o->>'nome','')),'') is not null;

  -- titular + acompanhantes define o tipo de quarto
  v_tipo := case when v_qtd = 0 then 'single'
                 when v_qtd = 1 then 'duplo'
                 else 'triplo' end;

  if v_qtd > 2 then
    raise exception 'O quarto comporta no maximo 3 pessoas (voce + 2). Fale com a organizacao.';
  end if;

  select id into v_res from reservas
  where participante_id = v_part and status <> 'cancelado'
  for update;

  if v_res is null then
    insert into reservas (evento_id, participante_id, rotulo, tipo, origem,
                          usa_transfer, transfer_origem, status)
    values (v_evento, v_part, 'Hospedagem', v_tipo, 'inscricao',
            coalesce(p_usa_transfer,false), p_transfer_origem, 'completo')
    returning id into v_res;
  else
    update reservas
       set tipo = v_tipo,
           usa_transfer = coalesce(p_usa_transfer,false),
           transfer_origem = p_transfer_origem,
           status = 'completo'
     where id = v_res;
  end if;

  delete from ocupantes where reserva_id = v_res;

  select g2.nome, g2.cpf, g2.email, g2.telefone into g
  from participantes pa join gestores g2 on g2.id = pa.gestor_id
  where pa.id = v_part;

  insert into ocupantes (reserva_id, nome, cpf, tipo, usa_transfer,
                         categoria_cracha, email, telefone)
  values (v_res, g.nome, g.cpf, 'titular', coalesce(p_usa_transfer,false),
          'PROTAGONISTA', g.email, g.telefone);

  insert into ocupantes (reserva_id, nome, cpf, data_nascimento, tipo,
                         usa_transfer, categoria_cracha)
  select v_res,
         trim(o->>'nome'),
         nullif(trim(coalesce(o->>'cpf','')),''),
         nullif(o->>'data_nascimento','')::date,
         coalesce(nullif(o->>'tipo',''),'adulto'),
         coalesce((o->>'usa_transfer')::boolean,false),
         'ACOMPANHANTE'
  from jsonb_array_elements(coalesce(p_acompanhantes,'[]'::jsonb)) o
  where nullif(trim(coalesce(o->>'nome','')),'') is not null;

  perform _recalcular_fatura_participante(v_part);

  insert into notificacoes (evento_id, destinatario, tipo, assunto)
  values (v_evento, g.email, 'rooming_ok', 'Dados de hospedagem confirmados');

  return jsonb_build_object('ok', true, 'reserva_id', v_res, 'ocupantes', v_qtd + 1);
end;
$$;

-- =====================================================================
-- 4. PERMISSOES
-- part_autocadastro fica aberta ao anon de proposito: e o unico jeito
-- de quem nao tem cadastro entrar na fila. As demais exigem JWT.
-- =====================================================================
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig, p.proname
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'gestao'
      and p.proname like 'part%'
      and p.proname <> 'part_autocadastro'
  loop
    execute format('revoke execute on function %s from anon', f.sig);
  end loop;
end $$;

revoke execute on function meu_participante(text) from anon;
revoke execute on function recalc_fatura_participante(uuid) from anon;
