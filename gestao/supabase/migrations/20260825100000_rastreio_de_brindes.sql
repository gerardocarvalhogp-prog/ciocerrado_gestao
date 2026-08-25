-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Rastreio de brindes: da promessa ate o quarto.
--
-- O QUE EXISTIA
--
-- O patrocinador marcava "vamos enviar brinde" e escrevia o que era, na
-- tela do quarto. A informacao morria ali: nenhuma funcao lia, nenhuma
-- tela da organizacao mostrava. No dia do evento alguem descobria na
-- portaria quantas caixas tinham chegado, contando.
--
-- O CAMINHO DE UM BRINDE
--
--   prometido   o patrocinador disse que vai mandar
--   enviado     postou, e informou transportadora e codigo
--   recebido    chegou no resort, alguem da equipe conferiu
--   entregue    foi para o quarto / para a mao do convidado
--   cancelado   desistiu, ou nao chegou a tempo
--
-- A escada NAO e obrigatoria. Brinde que o patrocinador leva na mala
-- pula de `prometido` para `recebido` sem nunca ter rastreio, e isso e
-- normal — a validacao aceita qualquer estado valido, e so carimba a
-- data certa.
--
-- UM CODIGO, VARIOS BRINDES
--
-- O brinde e por QUARTO (uma linha por reserva), mas o patrocinador nao
-- posta uma caixa por quarto: posta uma caixa com tudo. Por isso
-- `patro_informar_rastreio` recebe a empresa, e nao o brinde — um
-- codigo cai de uma vez em todos os brindes prometidos dela. Quem
-- precisar de granularidade fina continua tendo a linha por quarto para
-- marcar `entregue` um a um.
-- =====================================================================

set search_path = gestao, public;

-- ---------------------------------------------------------------------
-- 1. AS COLUNAS
-- ---------------------------------------------------------------------
alter table brindes add column if not exists status text not null default 'prometido';
alter table brindes add column if not exists transportadora text;
alter table brindes add column if not exists rastreio text;
alter table brindes add column if not exists enviado_em timestamptz;
alter table brindes add column if not exists recebido_em timestamptz;
alter table brindes add column if not exists recebido_por text;
alter table brindes add column if not exists entregue_em timestamptz;
alter table brindes add column if not exists entregue_por text;

alter table brindes drop constraint if exists brindes_status_check;
alter table brindes add constraint brindes_status_check
  check (status in ('prometido','enviado','recebido','entregue','cancelado'));

comment on column brindes.status is
  'prometido -> enviado -> recebido -> entregue, ou cancelado. A escada nao e obrigatoria.';
comment on column brindes.rastreio is
  'Codigo da transportadora. Um mesmo codigo cobre varios brindes: a empresa posta uma caixa so.';

-- ---------------------------------------------------------------------
-- 2. O QUE O PATROCINADOR VE
-- ---------------------------------------------------------------------
create or replace function patro_meus_brindes(p_patrocinador_id uuid)
returns table (
  brinde_id uuid,
  quarto text,
  descricao text,
  quantidade int,
  status text,
  transportadora text,
  rastreio text,
  enviado_em timestamptz,
  recebido_em timestamptz,
  entregue_em timestamptz
)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_patrocinador(p_patrocinador_id);

  return query
    select b.id, coalesce(q.numero, r.rotulo), b.descricao, b.quantidade,
           b.status, b.transportadora, b.rastreio,
           b.enviado_em, b.recebido_em, b.entregue_em
    from brindes b
    left join reservas r on r.id = b.reserva_id
    left join quartos  q on q.id = r.quarto_id
    where b.patrocinador_id = p_patrocinador_id
      and b.vai_enviar
    order by coalesce(q.numero, r.rotulo);
end;
$$;

-- Um codigo de rastreio para tudo que a empresa prometeu.
create or replace function patro_informar_rastreio(
  p_patrocinador_id uuid,
  p_transportadora text,
  p_rastreio text
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_n int;
begin
  perform _exige_patrocinador(p_patrocinador_id);

  if coalesce(trim(p_rastreio),'') = '' then
    raise exception 'Informe o codigo de rastreio' using errcode = '22023';
  end if;

  -- `enviado` tambem entra: corrigir um codigo digitado errado e caso
  -- comum, e obrigar a organizacao a desfazer seria pior.
  update brindes set
    transportadora = nullif(trim(p_transportadora),''),
    rastreio       = trim(p_rastreio),
    status         = 'enviado',
    enviado_em     = coalesce(enviado_em, now()),
    updated_at     = now()
  where patrocinador_id = p_patrocinador_id
    and vai_enviar
    and status in ('prometido','enviado');

  get diagnostics v_n = row_count;

  if v_n = 0 then
    raise exception 'Nenhum brinde pendente de envio nesta empresa'
      using errcode = 'P0002';
  end if;

  return jsonb_build_object('ok', true, 'brindes', v_n);
end;
$$;

-- ---------------------------------------------------------------------
-- 3. O QUE A ORGANIZACAO VE
-- ---------------------------------------------------------------------
create or replace function admin_brindes_resumo(p_evento_slug text)
returns jsonb language plpgsql stable security definer
set search_path = gestao, public as $$
declare v_out jsonb;
begin
  perform _exige_staff();

  select jsonb_build_object(
    'total',      count(*),
    'prometido',  count(*) filter (where b.status = 'prometido'),
    'enviado',    count(*) filter (where b.status = 'enviado'),
    'recebido',   count(*) filter (where b.status = 'recebido'),
    'entregue',   count(*) filter (where b.status = 'entregue'),
    'cancelado',  count(*) filter (where b.status = 'cancelado'),
    'empresas',   count(distinct b.patrocinador_id))
  into v_out
  from brindes b
  join patrocinadores p on p.id = b.patrocinador_id
  join eventos e on e.id = p.evento_id and e.slug = p_evento_slug
  where b.vai_enviar;

  return coalesce(v_out, jsonb_build_object('total', 0));
end;
$$;

create or replace function admin_listar_brindes(
  p_evento_slug text,
  p_status text default null,
  p_limite int default 500,
  p_offset int default 0
) returns table (
  brinde_id uuid,
  empresa text,
  cota text,
  quarto text,
  descricao text,
  quantidade int,
  status text,
  transportadora text,
  rastreio text,
  enviado_em timestamptz,
  recebido_em timestamptz,
  recebido_por text,
  entregue_em timestamptz,
  entregue_por text,
  observacao text
)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();

  return query
    select b.id, p.empresa, c.nome, coalesce(q.numero, r.rotulo),
           b.descricao, b.quantidade, b.status,
           b.transportadora, b.rastreio,
           b.enviado_em, b.recebido_em, b.recebido_por,
           b.entregue_em, b.entregue_por, b.observacao
    from brindes b
    join patrocinadores p on p.id = b.patrocinador_id
    join eventos e on e.id = p.evento_id and e.slug = p_evento_slug
    left join cotas    c on c.id = p.cota_id
    left join reservas r on r.id = b.reserva_id
    left join quartos  q on q.id = r.quarto_id
    where b.vai_enviar
      and (p_status is null or b.status = p_status)
    -- quem ainda nao chegou primeiro: e essa a lista que alguem precisa
    -- olhar na vespera
    order by case b.status
               when 'prometido' then 1 when 'enviado' then 2
               when 'recebido'  then 3 when 'entregue' then 4
               else 5 end,
             p.empresa, coalesce(q.numero, r.rotulo)
    limit greatest(coalesce(p_limite, 500), 1)
    offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

create or replace function admin_marcar_brinde(
  p_brinde_id uuid,
  p_status text,
  p_observacao text default null
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_ant text; v_quem text;
begin
  perform _exige_staff();

  select status into v_ant from brindes where id = p_brinde_id;
  if v_ant is null then
    raise exception 'Brinde nao encontrado' using errcode = 'P0002';
  end if;
  if p_status not in ('prometido','enviado','recebido','entregue','cancelado') then
    raise exception 'Status invalido: %', p_status using errcode = '22023';
  end if;

  v_quem := auth.jwt() ->> 'email';

  update brindes set
    status = p_status,
    -- carimba na primeira vez que entra no estado e LIMPA ao voltar
    -- atras: brinde reaberto com data de entrega antiga faz a
    -- conferencia da vespera mentir
    enviado_em = case
      when p_status in ('enviado','recebido','entregue') then coalesce(enviado_em, now())
      else null end,
    recebido_em = case
      when p_status in ('recebido','entregue') then coalesce(recebido_em, now())
      else null end,
    recebido_por = case
      when p_status in ('recebido','entregue') then coalesce(recebido_por, v_quem)
      else null end,
    entregue_em = case
      when p_status = 'entregue' then coalesce(entregue_em, now())
      else null end,
    entregue_por = case
      when p_status = 'entregue' then coalesce(entregue_por, v_quem)
      else null end,
    observacao = coalesce(p_observacao, observacao),
    updated_at = now()
  where id = p_brinde_id;

  return jsonb_build_object('ok', true, 'de', v_ant, 'para', p_status);
end;
$$;

-- ---------------------------------------------------------------------
-- 4. PERMISSAO
-- ---------------------------------------------------------------------
revoke execute on function patro_meus_brindes(uuid) from public, anon;
revoke execute on function patro_informar_rastreio(uuid, text, text) from public, anon;
revoke execute on function admin_brindes_resumo(text) from public, anon;
revoke execute on function admin_listar_brindes(text, text, int, int) from public, anon;
revoke execute on function admin_marcar_brinde(uuid, text, text) from public, anon;

grant execute on function patro_meus_brindes(uuid) to authenticated, service_role;
grant execute on function patro_informar_rastreio(uuid, text, text) to authenticated, service_role;
grant execute on function admin_brindes_resumo(text) to authenticated, service_role;
grant execute on function admin_listar_brindes(text, text, int, int) to authenticated, service_role;
grant execute on function admin_marcar_brinde(uuid, text, text) to authenticated, service_role;
