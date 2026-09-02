-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Sistema de upload do patrocinador: logo, banner, arte de revista,
-- apresentação, vídeo — condicionados à cota, com tela admin pra
-- revisar e integração com o módulo de pendência/cobrança que já
-- existia (v_pendencias).
--
-- CADA COTA DECIDE O QUE PEDE
--
-- 5 booleans em `cotas` (upload_logo, upload_banner, ...), mesmo
-- padrão de tem_reuniao_exclusiva/tem_jantar — nenhuma migration
-- futura precisa mexer em código quando o organizador decidir que só
-- Esmeralda manda vídeo, por exemplo.
--
-- PRAZO: NA COTA OU NO EVENTO
--
-- cotas.prazo_upload (por cota) cai pra eventos.prazo_upload_padrao
-- (padrão do evento) se a cota não tiver o dela. É o mesmo desenho de
-- vencimento absoluto que fatura_paga já usa em v_pendencias — reusa
-- a categoria 'fatura' ali por isso: o significado prático daquela
-- categoria é "tem vencimento, não conta dia corrido", não fatura
-- literalmente.
--
-- ARMAZENAMENTO
--
-- Bucket privado `patrocinador-uploads`, caminho
-- <patrocinador_id>/<tipo>/<arquivo> — a policy de storage usa o
-- primeiro segmento do caminho pra saber de quem é o arquivo.
-- =====================================================================

set search_path = gestao, public;

alter table cotas add column if not exists upload_logo boolean not null default false;
alter table cotas add column if not exists upload_banner boolean not null default false;
alter table cotas add column if not exists upload_arte_revista boolean not null default false;
alter table cotas add column if not exists upload_apresentacao boolean not null default false;
alter table cotas add column if not exists upload_video boolean not null default false;
alter table cotas add column if not exists prazo_upload date;

alter table eventos add column if not exists prazo_upload_padrao date;
comment on column eventos.prazo_upload_padrao is
  'Prazo padrao de upload pra cota que nao tem prazo_upload proprio. NULL nos dois = sem prazo (etapa some de v_pendencias, mesmo padrao das outras).';

create table if not exists patrocinador_uploads (
  id               uuid primary key default gen_random_uuid(),
  patrocinador_id  uuid not null references patrocinadores(id) on delete cascade,
  tipo             text not null check (tipo in ('logo','banner','arte_revista','apresentacao','video')),
  storage_path     text not null,
  nome_arquivo     text,
  tamanho_bytes    bigint,
  status           text not null default 'enviado' check (status in ('enviado','aprovado','rejeitado')),
  observacao_admin text,
  enviado_em       timestamptz not null default now(),
  enviado_por      text,
  unique (patrocinador_id, tipo)
);
comment on table patrocinador_uploads is
  'Um arquivo por (patrocinador, tipo) — reenviar substitui a linha. O arquivo antigo no storage fica orfao (removido pelo cliente, nao por SQL) ate a rotina de limpeza existir.';

alter table patrocinador_uploads enable row level security;
create policy patrocinador_uploads_staff_all on patrocinador_uploads
  for all to authenticated using (is_staff()) with check (is_staff());
revoke all on table patrocinador_uploads from anon, authenticated;

-- ---------------------------------------------------------------------
-- 1. BUCKET E POLICIES DE STORAGE
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit)
values ('patrocinador-uploads', 'patrocinador-uploads', false, 209715200) -- 200MB, cobre video
on conflict (id) do nothing;

drop policy if exists "patro_uploads_insert_propria_pasta" on storage.objects;
drop policy if exists "patro_uploads_select_propria_pasta_ou_staff" on storage.objects;
drop policy if exists "patro_uploads_staff_gerencia_tudo" on storage.objects;

create policy "patro_uploads_insert_propria_pasta" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'patrocinador-uploads'
    and (storage.foldername(name))[1]::uuid in (select gestao.meus_patrocinadores())
  );

create policy "patro_uploads_select_propria_pasta_ou_staff" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'patrocinador-uploads'
    and (
      (storage.foldername(name))[1]::uuid in (select gestao.meus_patrocinadores())
      or gestao.is_staff()
    )
  );

create policy "patro_uploads_staff_gerencia_tudo" on storage.objects
  for all to authenticated
  using (bucket_id = 'patrocinador-uploads' and gestao.is_staff())
  with check (bucket_id = 'patrocinador-uploads' and gestao.is_staff());

-- ---------------------------------------------------------------------
-- 2. O QUE O PATROCINADOR VE E ENVIA
-- ---------------------------------------------------------------------
create or replace function patro_meus_uploads(p_patrocinador_id uuid)
returns table (tipo text, obrigatorio boolean, upload_id uuid, storage_path text,
               nome_arquivo text, tamanho_bytes bigint, status text,
               observacao_admin text, enviado_em timestamptz, prazo date)
language plpgsql stable security definer
set search_path = gestao, public as $$
declare v_evento uuid; v_prazo date;
begin
  perform _exige_patrocinador(p_patrocinador_id);

  select p.evento_id into v_evento from patrocinadores p where p.id = p_patrocinador_id;

  select coalesce(c.prazo_upload, e.prazo_upload_padrao) into v_prazo
  from patrocinadores p
  join cotas c on c.id = p.cota_id
  join eventos e on e.id = p.evento_id
  where p.id = p_patrocinador_id;

  return query
    select t.tipo, t.obrigatorio, u.id, u.storage_path, u.nome_arquivo,
           u.tamanho_bytes, u.status, u.observacao_admin, u.enviado_em, v_prazo
    from (
      select unnest(array['logo','banner','arte_revista','apresentacao','video']) as tipo,
             unnest(array[c.upload_logo, c.upload_banner, c.upload_arte_revista,
                          c.upload_apresentacao, c.upload_video]) as obrigatorio
      from patrocinadores p join cotas c on c.id = p.cota_id
      where p.id = p_patrocinador_id
    ) t
    left join patrocinador_uploads u
      on u.patrocinador_id = p_patrocinador_id and u.tipo = t.tipo
    where t.obrigatorio
    order by t.tipo;
end;
$$;

create or replace function patro_registrar_upload(
  p_patrocinador_id uuid, p_tipo text, p_storage_path text,
  p_nome_arquivo text, p_tamanho_bytes bigint DEFAULT NULL::bigint
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_id uuid;
begin
  perform _exige_patrocinador(p_patrocinador_id);

  if p_tipo not in ('logo','banner','arte_revista','apresentacao','video') then
    raise exception 'Tipo de arquivo invalido: %', p_tipo using errcode = '22023';
  end if;

  insert into patrocinador_uploads (patrocinador_id, tipo, storage_path, nome_arquivo,
                                    tamanho_bytes, status, enviado_por)
  values (p_patrocinador_id, p_tipo, p_storage_path, p_nome_arquivo,
          p_tamanho_bytes, 'enviado', auth.jwt() ->> 'email')
  on conflict (patrocinador_id, tipo) do update set
    storage_path = excluded.storage_path,
    nome_arquivo = excluded.nome_arquivo,
    tamanho_bytes = excluded.tamanho_bytes,
    status = 'enviado',
    observacao_admin = null,
    enviado_em = now(),
    enviado_por = excluded.enviado_por
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

create or replace function patro_remover_upload(p_upload_id uuid)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_patro uuid; v_path text;
begin
  select patrocinador_id, storage_path into v_patro, v_path
  from patrocinador_uploads where id = p_upload_id;
  perform _exige_patrocinador(v_patro);

  delete from patrocinador_uploads where id = p_upload_id;

  return jsonb_build_object('ok', true, 'storage_path', v_path);
end;
$$;

revoke execute on function patro_meus_uploads(uuid) from public, anon;
revoke execute on function patro_registrar_upload(uuid,text,text,text,bigint) from public, anon;
revoke execute on function patro_remover_upload(uuid) from public, anon;
grant execute on function patro_meus_uploads(uuid) to authenticated, service_role;
grant execute on function patro_registrar_upload(uuid,text,text,text,bigint) to authenticated, service_role;
grant execute on function patro_remover_upload(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 3. O QUE A ORGANIZACAO VE E REVISA
-- ---------------------------------------------------------------------
create or replace function admin_listar_uploads(p_evento_slug text, p_status text DEFAULT NULL::text)
returns table (id uuid, patrocinador_id uuid, empresa text, tipo text, storage_path text,
               nome_arquivo text, tamanho_bytes bigint, status text, observacao_admin text,
               enviado_em timestamptz)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);
  return query
    select u.id, u.patrocinador_id, p.empresa, u.tipo, u.storage_path, u.nome_arquivo,
           u.tamanho_bytes, u.status, u.observacao_admin, u.enviado_em
    from patrocinador_uploads u
    join patrocinadores p on p.id = u.patrocinador_id
    join eventos e on e.id = p.evento_id and e.slug = p_evento_slug
    where p_status is null or u.status = p_status
    order by u.enviado_em desc;
end;
$$;

create or replace function admin_revisar_upload(p_upload_id uuid, p_status text, p_observacao text DEFAULT NULL::text)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
begin
  perform _exige_admin();

  if p_status not in ('aprovado','rejeitado') then
    raise exception 'Status invalido: %', p_status using errcode = '22023';
  end if;

  update patrocinador_uploads set
    status = p_status,
    observacao_admin = p_observacao
  where id = p_upload_id;

  if not found then
    raise exception 'Arquivo nao encontrado' using errcode = 'P0002';
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

revoke execute on function admin_listar_uploads(text,text) from public, anon;
revoke execute on function admin_revisar_upload(uuid,text,text) from public, anon;
grant execute on function admin_listar_uploads(text,text) to authenticated, service_role;
grant execute on function admin_revisar_upload(uuid,text,text) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 4. INTEGRACAO COM PENDENCIA/COBRANCA
-- ---------------------------------------------------------------------
insert into etapas_config (chave, publico, categoria, rotulo, ordem) values
  ('arquivos_enviados', 'patrocinador', 'fatura', 'Arquivos enviados (logo/banner/arte/apresentação/vídeo)', 7)
on conflict (chave) do nothing;

create or replace view v_pendencias_fatos as
  select pa.evento_id, 'participante'::text as publico, pa.id as sujeito_id,
         g.nome as sujeito_nome, g.empresa as sujeito_empresa,
         'inscricao_aprovada'::text as etapa_chave,
         pa.created_at as aberta_em, pa.aprovado_em as concluida_em,
         null::date as vencimento, g.email as destinatario_email
  from participantes pa
  join gestores g on g.id = pa.gestor_id
  where pa.status not in ('recusado','cancelado')

  union all
  select pa.evento_id, 'participante', pa.id, g.nome, g.empresa,
         'contrato_assinado', pa.aprovado_em, c.assinado_em,
         null, g.email
  from participantes pa
  join gestores g on g.id = pa.gestor_id
  left join contratos c on c.participante_id = pa.id
  where pa.status = 'aprovado'
    and (c.status is null or c.status not in ('recusado','cancelado'))

  union all
  select pa.evento_id, 'participante', pa.id, g.nome, g.empresa,
         'hospedagem_preenchida', c.assinado_em, r.completo_em,
         null, g.email
  from participantes pa
  join gestores g on g.id = pa.gestor_id
  join contratos c on c.participante_id = pa.id and c.status = 'assinado'
  left join reservas r on r.participante_id = pa.id and r.status <> 'cancelado'

  union all
  select f.evento_id, 'participante', f.participante_id, g.nome, g.empresa,
         'fatura_paga', f.created_at, f.paga_em,
         f.vencimento, g.email
  from faturas f
  join participantes pa on pa.id = f.participante_id
  join gestores g on g.id = pa.gestor_id
  where f.status <> 'cancelada' and f.total > 0

  union all
  select s.evento_id, 'participante', sc.participante_id, g.nome, g.empresa,
         'presenca_confirmada', sc.created_at, sc.resposta_em,
         null, g.email
  from sessao_convidados sc
  join sessoes s on s.id = sc.sessao_id
  join participantes pa on pa.id = sc.participante_id
  join gestores g on g.id = pa.gestor_id
  where sc.status = 'confirmado'

  union all
  select p.evento_id, 'patrocinador', p.id, null, p.empresa,
         'contrato_patrocinio_assinado', p.created_at, c.assinado_em,
         null, null
  from patrocinadores p
  left join contratos c on c.patrocinador_id = p.id
  where p.status = 'ativo'

  union all
  select p.evento_id, 'patrocinador', p.id, null, p.empresa,
         'indicacao_cio_feita', p.created_at,
         (select min(i.created_at) from indicacoes i where i.patrocinador_id = p.id),
         null, null
  from patrocinadores p
  join cotas co on co.id = p.cota_id
  where p.status = 'ativo' and co.vagas_mesa_redonda > 0

  union all
  select p.evento_id, 'patrocinador', p.id, null, p.empresa,
         'quartos_preenchidos', p.created_at, p.fechado_em,
         null, null
  from patrocinadores p
  join cotas co on co.id = p.cota_id
  where p.status = 'ativo' and (co.quartos_incluidos > 0 or p.quartos_extras_cota > 0)

  union all
  select s.evento_id, 'patrocinador', s.patrocinador_id, null, p.empresa,
         case s.tipo when 'mesa_redonda' then 'convidados_mesa_escolhidos'
                     else 'convidados_jantar_escolhidos' end,
         coalesce(s.escolha_liberada_em, s.created_at), s.escolha_encerrada_em,
         null, null
  from sessoes s
  join patrocinadores p on p.id = s.patrocinador_id
  where s.tipo in ('mesa_redonda','jantar') and p.status = 'ativo'

  union all
  select p.evento_id, 'patrocinador', p.id, null, p.empresa,
         'brindes_definidos', p.created_at,
         (select min(b.created_at) from brindes b where b.patrocinador_id = p.id and b.vai_enviar),
         null, null
  from patrocinadores p
  where p.status = 'ativo'

  union all
  -- 12. arquivos enviados — so entra na lista quem a cota exige pelo
  -- menos um tipo. Concluida quando TODOS os tipos exigidos tem linha
  -- em patrocinador_uploads (nao precisa estar aprovado — "enviou" ja
  -- fecha a etapa; aprovacao e outro controle, na tela de revisao)
  select p.evento_id, 'patrocinador', p.id, null, p.empresa,
         'arquivos_enviados', p.created_at,
         case when (
                select count(distinct u.tipo) from patrocinador_uploads u
                where u.patrocinador_id = p.id and u.tipo = any(v_req.tipos)
              ) >= array_length(v_req.tipos, 1)
              then (select max(u.enviado_em) from patrocinador_uploads u
                    where u.patrocinador_id = p.id and u.tipo = any(v_req.tipos))
              else null end,
         coalesce(co.prazo_upload, e2.prazo_upload_padrao),
         null
  from patrocinadores p
  join cotas co on co.id = p.cota_id
  join eventos e2 on e2.id = p.evento_id
  cross join lateral (
    select array_remove(array[
      case when co.upload_logo then 'logo' end,
      case when co.upload_banner then 'banner' end,
      case when co.upload_arte_revista then 'arte_revista' end,
      case when co.upload_apresentacao then 'apresentacao' end,
      case when co.upload_video then 'video' end
    ], null) as tipos
  ) v_req
  where p.status = 'ativo' and array_length(v_req.tipos, 1) > 0
;

create or replace view v_pendencias as
  select
    f.evento_id, f.publico, f.sujeito_id, f.sujeito_nome, f.sujeito_empresa,
    f.etapa_chave, ec.rotulo as etapa_rotulo, ec.ordem as etapa_ordem,
    f.aberta_em, f.concluida_em, f.vencimento, f.destinatario_email,
    case when f.concluida_em is not null then 'concluida' else 'pendente' end as status,
    case when f.concluida_em is not null then null
         else (current_date - f.aberta_em::date) end as dias_em_aberto,
    case
      when f.concluida_em is not null then 'ok'
      when f.etapa_chave in ('fatura_paga','arquivos_enviados') then
        case
          when f.vencimento is null then 'ok'
          when current_date > f.vencimento then 'atrasado'
          when current_date >= f.vencimento - 5 then 'atencao'
          else 'ok'
        end
      when pe.dias_atencao is null then 'ok'
      when (current_date - f.aberta_em::date) >= pe.dias_atrasado then 'atrasado'
      when (current_date - f.aberta_em::date) >= pe.dias_atencao then 'atencao'
      else 'ok'
    end as nivel
  from v_pendencias_fatos f
  join etapas_config ec on ec.chave = f.etapa_chave
  join prazos_evento pe on pe.evento_id = f.evento_id and pe.etapa_chave = f.etapa_chave and pe.ativo;

-- ---------------------------------------------------------------------
-- 5. TEXTO DA COBRANCA
-- ---------------------------------------------------------------------
create or replace function admin_preparar_cobranca(
  p_sujeito_id uuid, p_etapa_chave text
) returns jsonb language plpgsql stable security definer
set search_path = gestao, public as $$
declare
  v_row record;
  v_destinatarios text[];
  v_assunto text;
  v_corpo text;
  v_ultimo timestamptz;
begin
  perform _exige_staff();

  select * into v_row from v_pendencias
   where sujeito_id = p_sujeito_id and etapa_chave = p_etapa_chave
   limit 1;
  if v_row is null then
    raise exception 'Pendência não encontrada' using errcode = 'P0002';
  end if;
  if v_row.status = 'concluida' then
    raise exception 'Essa etapa já foi concluída — não há pendência para cobrar'
      using errcode = '55000';
  end if;

  if v_row.publico = 'participante' then
    v_destinatarios := array[v_row.destinatario_email];
  else
    select array_agg(up.email) into v_destinatarios
    from usuarios_patrocinador up
    where up.patrocinador_id = v_row.sujeito_id and up.ativo;
  end if;

  select max(n.created_at) into v_ultimo
  from notificacoes n
  where n.tipo = 'cobranca_' || p_etapa_chave
    and n.destinatario = any(coalesce(v_destinatarios, array[]::text[]))
    and n.created_at > now() - interval '3 days';

  v_assunto := 'CIO Cerrado — ' || v_row.etapa_rotulo;
  v_corpo := case v_row.etapa_chave
    when 'contrato_assinado' then
      'Olá! Notamos que o contrato ainda não foi assinado. Pode verificar quando tiver um momento?'
    when 'hospedagem_preenchida' then
      'Olá! Os dados de hospedagem ainda não foram preenchidos. O prazo está próximo — pode completar quando puder?'
    when 'fatura_paga' then
      'Olá! Há uma fatura em aberto. Qualquer dúvida sobre o valor, é só responder este e-mail.'
    when 'presenca_confirmada' then
      'Olá! Ainda não temos sua confirmação de presença. Pode confirmar quando puder?'
    when 'contrato_patrocinio_assinado' then
      'Olá! O contrato de patrocínio ainda não foi assinado. Pode verificar quando tiver um momento?'
    when 'indicacao_cio_feita' then
      'Olá! Ainda não recebemos indicações de CIOs da sua empresa para este evento.'
    when 'quartos_preenchidos' then
      'Olá! Os ocupantes dos quartos da cota ainda não foram todos preenchidos.'
    when 'convidados_mesa_escolhidos' then
      'Olá! Os convidados de mesa redonda ainda não foram escolhidos.'
    when 'convidados_jantar_escolhidos' then
      'Olá! Os convidados de jantar ainda não foram escolhidos.'
    when 'brindes_definidos' then
      'Olá! Ainda não recebemos a definição de brindes da sua empresa.'
    when 'arquivos_enviados' then
      'Olá! Ainda faltam arquivos da sua cota (logo, banner, arte de revista, apresentação ou vídeo, conforme o pacote). Pode enviar pelo portal quando puder?'
    else 'Olá! Notamos uma pendência: ' || v_row.etapa_rotulo || '.'
  end;

  return jsonb_build_object(
    'destinatarios', to_jsonb(coalesce(v_destinatarios, array[]::text[])),
    'assunto', v_assunto,
    'corpo', v_corpo,
    'dias_em_aberto', v_row.dias_em_aberto,
    'ja_enviado_recentemente', v_ultimo is not null,
    'ultimo_envio', v_ultimo
  );
end;
$$;

revoke execute on function admin_preparar_cobranca(uuid,text) from public, anon;
grant execute on function admin_preparar_cobranca(uuid,text) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 6. CADASTRO DA COTA E DO EVENTO GANHAM OS CAMPOS
-- ---------------------------------------------------------------------
drop function if exists admin_salvar_cota(text,text,integer,jsonb,integer,boolean,boolean,date,integer,integer,boolean);

create or replace function admin_salvar_cota(
  p_evento_slug text, p_nome text, p_ordem integer,
  p_quartos jsonb DEFAULT '{}'::jsonb, p_vagas_mesa integer DEFAULT 0,
  p_reuniao boolean DEFAULT false, p_jantar boolean DEFAULT false,
  p_prazo_indicacao date DEFAULT NULL::date, p_janela_horas integer DEFAULT NULL::integer,
  p_limite_indicacoes integer DEFAULT NULL::integer,
  p_escolhe_convidados boolean DEFAULT true,
  p_upload_logo boolean DEFAULT false, p_upload_banner boolean DEFAULT false,
  p_upload_arte_revista boolean DEFAULT false, p_upload_apresentacao boolean DEFAULT false,
  p_upload_video boolean DEFAULT false, p_prazo_upload date DEFAULT NULL::date
) returns jsonb language plpgsql security definer
set search_path to 'gestao', 'public' as $$
declare
  v_evento uuid; v_unica boolean; v_conflito text;
  v_cota uuid; v_par record; v_ordem int; v_total int := 0;
begin
  perform _exige_admin();

  select id, cota_unica into v_evento, v_unica
  from eventos where slug = p_evento_slug;

  if v_evento is null then
    raise exception 'Evento nao encontrado' using errcode='P0002';
  end if;
  if coalesce(trim(p_nome),'') = '' then
    raise exception 'Informe o nome da cota' using errcode='22023';
  end if;
  if p_janela_horas is not null and p_janela_horas <= 0 then
    raise exception 'A janela em horas comeca em 1' using errcode='22023';
  end if;
  if p_limite_indicacoes is not null and p_limite_indicacoes < 0 then
    raise exception 'O limite de indicacoes nao pode ser negativo' using errcode='22023';
  end if;

  v_ordem := case when v_unica then 1 else p_ordem end;

  if v_ordem is null or v_ordem < 1 then
    raise exception 'A ordem de prioridade comeca em 1' using errcode='22023';
  end if;

  if not v_unica then
    select c.nome into v_conflito from cotas c
     where c.evento_id = v_evento and c.ordem_prioridade = v_ordem
       and lower(c.nome) <> lower(trim(p_nome));
    if v_conflito is not null then
      raise exception 'A posicao % ja e da cota "%"', v_ordem, v_conflito
        using errcode='23505';
    end if;
  end if;

  insert into cotas (evento_id, nome, ordem_prioridade, vagas_mesa_redonda,
                     tem_reuniao_exclusiva, tem_jantar,
                     quartos_incluidos, tipo_quarto_padrao, prazo_indicacao,
                     janela_horas, limite_indicacoes, escolhe_convidados,
                     upload_logo, upload_banner, upload_arte_revista,
                     upload_apresentacao, upload_video, prazo_upload)
  values (v_evento, trim(p_nome), v_ordem, coalesce(p_vagas_mesa,0),
          p_reuniao, p_jantar, 0, 'duplo', p_prazo_indicacao, p_janela_horas,
          p_limite_indicacoes, coalesce(p_escolhe_convidados, true),
          coalesce(p_upload_logo,false), coalesce(p_upload_banner,false),
          coalesce(p_upload_arte_revista,false), coalesce(p_upload_apresentacao,false),
          coalesce(p_upload_video,false), p_prazo_upload)
  on conflict (evento_id, nome) do update set
    ordem_prioridade = excluded.ordem_prioridade,
    vagas_mesa_redonda = excluded.vagas_mesa_redonda,
    tem_reuniao_exclusiva = excluded.tem_reuniao_exclusiva,
    tem_jantar = excluded.tem_jantar,
    prazo_indicacao = excluded.prazo_indicacao,
    janela_horas = excluded.janela_horas,
    limite_indicacoes = excluded.limite_indicacoes,
    escolhe_convidados = excluded.escolhe_convidados,
    upload_logo = excluded.upload_logo,
    upload_banner = excluded.upload_banner,
    upload_arte_revista = excluded.upload_arte_revista,
    upload_apresentacao = excluded.upload_apresentacao,
    upload_video = excluded.upload_video,
    prazo_upload = excluded.prazo_upload
  returning id into v_cota;

  delete from cota_quartos where cota_id = v_cota;

  for v_par in
    select key as tipo, (value #>> '{}')::int as qtd
    from jsonb_each(coalesce(p_quartos, '{}'::jsonb))
  loop
    if v_par.tipo not in ('single','duplo','triplo') then
      raise exception 'Tipo de quarto invalido: %', v_par.tipo using errcode='22023';
    end if;
    if coalesce(v_par.qtd,0) > 0 then
      insert into cota_quartos (cota_id, tipo, quantidade)
      values (v_cota, v_par.tipo, v_par.qtd);
      v_total := v_total + v_par.qtd;
    end if;
  end loop;

  update cotas set quartos_incluidos = v_total where id = v_cota;

  return jsonb_build_object('ok', true, 'id', v_cota, 'total_quartos', v_total);
end;
$$;

drop function if exists admin_listar_cotas(text);

create or replace function admin_listar_cotas(p_evento_slug text)
returns table (
  id uuid, nome text, ordem_prioridade integer, quartos jsonb,
  total_quartos bigint, vagas_mesa_redonda integer,
  tem_reuniao_exclusiva boolean, tem_jantar boolean,
  patrocinadores bigint, lista_patrocinadores jsonb,
  prazo_indicacao date, janela_horas integer, limite_indicacoes integer,
  escolhe_convidados boolean,
  upload_logo boolean, upload_banner boolean, upload_arte_revista boolean,
  upload_apresentacao boolean, upload_video boolean, prazo_upload date
)
language plpgsql stable security definer
set search_path to 'gestao', 'public' as $$
begin
  perform _exige_staff();
  return query
    select c.id, c.nome, c.ordem_prioridade,
           coalesce((select jsonb_object_agg(cq.tipo, cq.quantidade)
                     from cota_quartos cq where cq.cota_id = c.id
                       and cq.quantidade > 0), '{}'::jsonb),
           coalesce((select sum(cq.quantidade) from cota_quartos cq
                     where cq.cota_id = c.id), 0),
           c.vagas_mesa_redonda, c.tem_reuniao_exclusiva, c.tem_jantar,
           (select count(*) from patrocinadores p where p.cota_id = c.id),
           coalesce((select jsonb_agg(jsonb_build_object(
                       'id', p.id, 'empresa', p.empresa) order by p.empresa)
                     from patrocinadores p
                     where p.cota_id = c.id and p.status = 'ativo'), '[]'::jsonb),
           c.prazo_indicacao, c.janela_horas, c.limite_indicacoes, c.escolhe_convidados,
           c.upload_logo, c.upload_banner, c.upload_arte_revista,
           c.upload_apresentacao, c.upload_video, c.prazo_upload
    from cotas c
    join eventos e on e.id = c.evento_id and e.slug = p_evento_slug
    order by c.ordem_prioridade;
end;
$$;

revoke execute on function admin_salvar_cota(text,text,integer,jsonb,integer,boolean,boolean,date,integer,integer,boolean,boolean,boolean,boolean,boolean,boolean,date) from public, anon;
revoke execute on function admin_listar_cotas(text) from public, anon;
grant execute on function admin_salvar_cota(text,text,integer,jsonb,integer,boolean,boolean,date,integer,integer,boolean,boolean,boolean,boolean,boolean,boolean,date) to authenticated, service_role;
grant execute on function admin_listar_cotas(text) to authenticated, service_role;

drop function if exists admin_salvar_evento(text,text,text,date,date,text,date,date,date,text,boolean,timestamptz,text);

create or replace function admin_salvar_evento(
  p_slug text, p_nome text, p_local text DEFAULT NULL::text,
  p_data_inicio date DEFAULT NULL::date, p_data_fim date DEFAULT NULL::date,
  p_status text DEFAULT 'rascunho'::text, p_prazo_contrato date DEFAULT NULL::date,
  p_prazo_rooming date DEFAULT NULL::date, p_prazo_cancelamento date DEFAULT NULL::date,
  p_sympla_event_id text DEFAULT NULL::text, p_cota_unica boolean DEFAULT false,
  p_escolha_abre_em timestamptz DEFAULT NULL::timestamptz, p_sympla_url text DEFAULT NULL::text,
  p_prazo_upload_padrao date DEFAULT NULL::date
) returns jsonb language plpgsql security definer
set search_path to 'gestao', 'public' as $$
declare v_slug text; v_id uuid; v_cotas int;
begin
  perform _exige_admin();

  v_slug := trim(both '-' from regexp_replace(
    lower(unaccent('unaccent', coalesce(trim(p_slug),''))), '[^a-z0-9]+','-','g'));

  if v_slug = '' then
    raise exception 'Informe o identificador do evento' using errcode='22023';
  end if;
  if coalesce(trim(p_nome),'') = '' then
    raise exception 'Informe o nome do evento' using errcode='22023';
  end if;
  if p_status not in ('rascunho','aberto','encerrado') then
    raise exception 'Status invalido: %', p_status using errcode='22023';
  end if;
  if p_data_inicio is not null and p_data_fim is not null
     and p_data_fim < p_data_inicio then
    raise exception 'A data final e anterior a inicial' using errcode='22023';
  end if;

  if p_cota_unica then
    select count(*) into v_cotas from cotas c
    join eventos e on e.id = c.evento_id
    where e.slug = v_slug;
    if v_cotas > 1 then
      raise exception
        'Este evento tem % cotas. Remova-as antes de marcar como cota unica.', v_cotas
        using errcode='22023';
    end if;
  end if;

  insert into eventos (slug, nome, local, data_inicio, data_fim, status,
                       prazo_contrato, prazo_rooming, prazo_cancelamento,
                       sympla_event_id, cota_unica, escolha_abre_em,
                       sympla_url, prazo_upload_padrao)
  values (v_slug, trim(p_nome), p_local, p_data_inicio, p_data_fim, p_status,
          p_prazo_contrato, p_prazo_rooming, p_prazo_cancelamento,
          p_sympla_event_id, coalesce(p_cota_unica,false), p_escolha_abre_em,
          nullif(trim(p_sympla_url),''), p_prazo_upload_padrao)
  on conflict (slug) do update set
    nome = excluded.nome, local = excluded.local,
    data_inicio = excluded.data_inicio, data_fim = excluded.data_fim,
    status = excluded.status,
    prazo_contrato = excluded.prazo_contrato,
    prazo_rooming = excluded.prazo_rooming,
    prazo_cancelamento = excluded.prazo_cancelamento,
    sympla_event_id = coalesce(excluded.sympla_event_id, eventos.sympla_event_id),
    cota_unica = excluded.cota_unica,
    escolha_abre_em = excluded.escolha_abre_em,
    sympla_url = coalesce(excluded.sympla_url, eventos.sympla_url),
    prazo_upload_padrao = excluded.prazo_upload_padrao
  returning id into v_id;

  if coalesce(p_cota_unica,false) then
    insert into cotas (evento_id, nome, ordem_prioridade, quartos_incluidos,
                       tipo_quarto_padrao, vagas_mesa_redonda,
                       tem_reuniao_exclusiva, tem_jantar)
    values (v_id, 'Única', 1, 0, 'duplo', 0, false, true)
    on conflict (evento_id, nome) do nothing;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id, 'slug', v_slug,
                            'cota_unica', coalesce(p_cota_unica,false));
end;
$$;

drop function if exists admin_listar_eventos();

create or replace function admin_listar_eventos()
returns table(id uuid, slug text, nome text, local text, data_inicio date, data_fim date,
              status text, cota_unica boolean, prazo_contrato date, prazo_rooming date,
              prazo_cancelamento date, participantes bigint, escolha_abre_em timestamptz,
              sympla_url text, sympla_event_id text, usa_atividades boolean,
              prazo_upload_padrao date)
language plpgsql stable security definer
set search_path to 'gestao', 'public' as $$
begin
  perform _exige_staff();
  return query
    select e.id, e.slug, e.nome, e.local, e.data_inicio, e.data_fim,
           e.status, e.cota_unica,
           e.prazo_contrato, e.prazo_rooming, e.prazo_cancelamento,
           (select count(*) from participantes p where p.evento_id = e.id),
           e.escolha_abre_em,
           e.sympla_url, e.sympla_event_id, e.usa_atividades, e.prazo_upload_padrao
    from eventos e
    where is_admin() or exists (
      select 1 from admins a
      join admin_eventos ae on ae.admin_id = a.id
      where a.email_norm = norm_doc(auth.jwt() ->> 'email')
        and a.ativo and ae.evento_id = e.id
    )
    order by e.data_inicio desc nulls last;
end;
$$;

revoke execute on function admin_salvar_evento(text,text,text,date,date,text,date,date,date,text,boolean,timestamptz,text,date) from public, anon;
revoke execute on function admin_listar_eventos() from public, anon;
grant execute on function admin_salvar_evento(text,text,text,date,date,text,date,date,date,text,boolean,timestamptz,text,date) to authenticated, service_role;
grant execute on function admin_listar_eventos() to authenticated, service_role;
