-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Bloco 3 — arquivos e logos.
--
-- 3.1/3.2 propriedades do arquivo (extensao deriva do nome, tamanho ja
--     existia) ganham largura/altura (só imagem, lido no navegador
--     antes do envio) e um botao de visualizar que abre a URL assinada
--     — que o navegador ja renderiza inline pra imagem/PDF, sem forcar
--     download (era so o rotulo "Baixar" que sugeria o contrario).
-- 3.3 logo/banner/arte de revista/apresentacao passam a exigir PDF no
--     input (accept + checagem client-side) — video fica como esta,
--     PDF nao serve pra video.
-- 3.4 logo vira MUITOS arquivos por patrocinador em vez de um so —
--     patrocinador_uploads ganha `ordem`, e a UNIQUE que era
--     (patrocinador_id, tipo) vira (patrocinador_id, tipo, ordem).
--     cotas.upload_logo (boolean) vira upload_logo_qtd (integer): 0 =
--     nao exige, N = exige N logos. Os outros 4 tipos continuam
--     boolean — nao fazem sentido em copia multipla.
-- 3.5 motivo de reprovacao — ja existia (patrocinador_uploads.
--     observacao_admin, devolvido por patro_meus_uploads e exibido em
--     portal.html). Nao mudou nada aqui.
-- =====================================================================

set search_path = gestao, public;

alter table patrocinador_uploads add column if not exists ordem integer not null default 1;
alter table patrocinador_uploads add column if not exists largura integer;
alter table patrocinador_uploads add column if not exists altura integer;

alter table patrocinador_uploads drop constraint if exists patrocinador_uploads_patrocinador_id_tipo_key;
drop index if exists patrocinador_uploads_patrocinador_id_tipo_key;
alter table patrocinador_uploads add constraint patrocinador_uploads_patrocinador_id_tipo_ordem_key
  unique (patrocinador_id, tipo, ordem);

comment on table patrocinador_uploads is
  'Um arquivo por (patrocinador, tipo, ordem) — reenviar a mesma ordem substitui a linha. Tipo logo pode ter varias ordens (1..upload_logo_qtd da cota); os outros 4 tipos sempre usam ordem=1. O arquivo antigo no storage fica orfao (removido pelo cliente, nao por SQL) ate a rotina de limpeza existir.';

alter table cotas add column if not exists upload_logo_qtd integer not null default 0;
update cotas set upload_logo_qtd = case when upload_logo then 1 else 0 end
  where upload_logo_qtd = 0;
-- so dropa upload_logo la no fim do arquivo: v_pendencias_fatos ainda
-- referencia a coluna ate ser redefinida mais abaixo, e DROP COLUMN
-- com dependente vivo falha (a view teria que ir com CASCADE, o que
-- apagaria v_pendencias tambem sem necessidade).

-- ---------------------------------------------------------------------
-- 5.1/3.4: admin_salvar_cota troca p_upload_logo boolean por
-- p_upload_logo_qtd integer — muda o tipo do parametro, exige DROP.
-- ---------------------------------------------------------------------
drop function if exists admin_salvar_cota(text,text,integer,jsonb,integer,boolean,boolean,date,integer,integer,boolean,boolean,boolean,boolean,boolean,boolean,date,numeric);

create function admin_salvar_cota(
  p_evento_slug text, p_nome text, p_ordem integer,
  p_quartos jsonb DEFAULT '{}'::jsonb, p_vagas_mesa integer DEFAULT 0,
  p_reuniao boolean DEFAULT false, p_jantar boolean DEFAULT false,
  p_prazo_indicacao date DEFAULT NULL::date, p_janela_horas integer DEFAULT NULL::integer,
  p_limite_indicacoes integer DEFAULT NULL::integer,
  p_escolhe_convidados boolean DEFAULT true,
  p_upload_logo_qtd integer DEFAULT 0, p_upload_banner boolean DEFAULT false,
  p_upload_arte_revista boolean DEFAULT false, p_upload_apresentacao boolean DEFAULT false,
  p_upload_video boolean DEFAULT false, p_prazo_upload date DEFAULT NULL::date,
  p_valor_sugerido numeric DEFAULT NULL::numeric
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
  if coalesce(p_upload_logo_qtd,0) < 0 then
    raise exception 'A quantidade de logos nao pode ser negativa' using errcode='22023';
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
                     upload_logo_qtd, upload_banner, upload_arte_revista,
                     upload_apresentacao, upload_video, prazo_upload,
                     valor_sugerido)
  values (v_evento, trim(p_nome), v_ordem, coalesce(p_vagas_mesa,0),
          p_reuniao, p_jantar, 0, 'duplo', p_prazo_indicacao, p_janela_horas,
          p_limite_indicacoes, coalesce(p_escolhe_convidados, true),
          coalesce(p_upload_logo_qtd,0), coalesce(p_upload_banner,false),
          coalesce(p_upload_arte_revista,false), coalesce(p_upload_apresentacao,false),
          coalesce(p_upload_video,false), p_prazo_upload, p_valor_sugerido)
  on conflict (evento_id, nome) do update set
    ordem_prioridade = excluded.ordem_prioridade,
    vagas_mesa_redonda = excluded.vagas_mesa_redonda,
    tem_reuniao_exclusiva = excluded.tem_reuniao_exclusiva,
    tem_jantar = excluded.tem_jantar,
    prazo_indicacao = excluded.prazo_indicacao,
    janela_horas = excluded.janela_horas,
    limite_indicacoes = excluded.limite_indicacoes,
    escolhe_convidados = excluded.escolhe_convidados,
    upload_logo_qtd = excluded.upload_logo_qtd,
    upload_banner = excluded.upload_banner,
    upload_arte_revista = excluded.upload_arte_revista,
    upload_apresentacao = excluded.upload_apresentacao,
    upload_video = excluded.upload_video,
    prazo_upload = excluded.prazo_upload,
    valor_sugerido = excluded.valor_sugerido
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

revoke execute on function admin_salvar_cota(text,text,integer,jsonb,integer,boolean,boolean,date,integer,integer,boolean,integer,boolean,boolean,boolean,boolean,date,numeric) from public, anon;
grant execute on function admin_salvar_cota(text,text,integer,jsonb,integer,boolean,boolean,date,integer,integer,boolean,integer,boolean,boolean,boolean,boolean,date,numeric) to authenticated, service_role;

drop function if exists admin_listar_cotas(text);

create function admin_listar_cotas(p_evento_slug text) returns table (
  id uuid, nome text, ordem_prioridade integer, quartos jsonb,
  total_quartos bigint, vagas_mesa_redonda integer,
  tem_reuniao_exclusiva boolean, tem_jantar boolean,
  patrocinadores bigint, lista_patrocinadores jsonb,
  prazo_indicacao date, janela_horas integer, limite_indicacoes integer,
  escolhe_convidados boolean,
  upload_logo_qtd integer, upload_banner boolean, upload_arte_revista boolean,
  upload_apresentacao boolean, upload_video boolean, prazo_upload date,
  valor_sugerido numeric
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
           c.upload_logo_qtd, c.upload_banner, c.upload_arte_revista,
           c.upload_apresentacao, c.upload_video, c.prazo_upload,
           c.valor_sugerido
    from cotas c
    join eventos e on e.id = c.evento_id and e.slug = p_evento_slug
    order by c.ordem_prioridade;
end;
$$;

revoke execute on function admin_listar_cotas(text) from public, anon;
grant execute on function admin_listar_cotas(text) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 3.1/3.4: patro_meus_uploads devolve N slots de logo (1..qtd) mais os
-- 4 tipos boolean — e as dimensoes, quando a linha e' imagem.
-- ---------------------------------------------------------------------
drop function if exists patro_meus_uploads(uuid);

create function patro_meus_uploads(p_patrocinador_id uuid)
returns table (tipo text, ordem integer, obrigatorio boolean, upload_id uuid, storage_path text,
               nome_arquivo text, tamanho_bytes bigint, largura integer, altura integer,
               status text, observacao_admin text, enviado_em timestamptz, prazo date)
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
    with cota as (
      select c.* from patrocinadores p join cotas c on c.id = p.cota_id
      where p.id = p_patrocinador_id
    ),
    slots as (
      select 'logo'::text as tipo, gs as ordem
      from cota, generate_series(1, greatest(upload_logo_qtd,0)) gs
      union all
      select 'banner', 1 from cota where upload_banner
      union all
      select 'arte_revista', 1 from cota where upload_arte_revista
      union all
      select 'apresentacao', 1 from cota where upload_apresentacao
      union all
      select 'video', 1 from cota where upload_video
    )
    select s.tipo, s.ordem, true, u.id, u.storage_path, u.nome_arquivo,
           u.tamanho_bytes, u.largura, u.altura, u.status, u.observacao_admin,
           u.enviado_em, v_prazo
    from slots s
    left join patrocinador_uploads u
      on u.patrocinador_id = p_patrocinador_id and u.tipo = s.tipo and u.ordem = s.ordem
    order by s.tipo, s.ordem;
end;
$$;

revoke execute on function patro_meus_uploads(uuid) from public, anon;
grant execute on function patro_meus_uploads(uuid) to authenticated, service_role;

drop function if exists patro_registrar_upload(uuid,text,text,text,bigint);

create function patro_registrar_upload(
  p_patrocinador_id uuid, p_tipo text, p_storage_path text,
  p_nome_arquivo text, p_tamanho_bytes bigint DEFAULT NULL::bigint,
  p_ordem integer DEFAULT 1, p_largura integer DEFAULT NULL::integer,
  p_altura integer DEFAULT NULL::integer
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_id uuid;
begin
  perform _exige_patrocinador(p_patrocinador_id);

  if p_tipo not in ('logo','banner','arte_revista','apresentacao','video') then
    raise exception 'Tipo de arquivo invalido: %', p_tipo using errcode = '22023';
  end if;
  if coalesce(p_ordem,1) < 1 then
    raise exception 'Ordem invalida: %', p_ordem using errcode = '22023';
  end if;

  insert into patrocinador_uploads (patrocinador_id, tipo, ordem, storage_path, nome_arquivo,
                                    tamanho_bytes, largura, altura, status, enviado_por)
  values (p_patrocinador_id, p_tipo, coalesce(p_ordem,1), p_storage_path, p_nome_arquivo,
          p_tamanho_bytes, p_largura, p_altura, 'enviado', auth.jwt() ->> 'email')
  on conflict (patrocinador_id, tipo, ordem) do update set
    storage_path = excluded.storage_path,
    nome_arquivo = excluded.nome_arquivo,
    tamanho_bytes = excluded.tamanho_bytes,
    largura = excluded.largura,
    altura = excluded.altura,
    status = 'enviado',
    observacao_admin = null,
    enviado_em = now(),
    enviado_por = excluded.enviado_por
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

revoke execute on function patro_registrar_upload(uuid,text,text,text,bigint,integer,integer,integer) from public, anon;
grant execute on function patro_registrar_upload(uuid,text,text,text,bigint,integer,integer,integer) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- ordem tambem passa a aparecer pra quem revisa (admin.html)
-- ---------------------------------------------------------------------
drop function if exists admin_listar_uploads(text,text);

create function admin_listar_uploads(p_evento_slug text, p_status text DEFAULT NULL::text)
returns table (id uuid, patrocinador_id uuid, empresa text, tipo text, ordem integer,
               storage_path text, nome_arquivo text, tamanho_bytes bigint,
               largura integer, altura integer, status text, observacao_admin text,
               enviado_em timestamptz)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);
  return query
    select u.id, u.patrocinador_id, p.empresa, u.tipo, u.ordem, u.storage_path, u.nome_arquivo,
           u.tamanho_bytes, u.largura, u.altura, u.status, u.observacao_admin, u.enviado_em
    from patrocinador_uploads u
    join patrocinadores p on p.id = u.patrocinador_id
    join eventos e on e.id = p.evento_id and e.slug = p_evento_slug
    where p_status is null or u.status = p_status
    order by u.enviado_em desc;
end;
$$;

revoke execute on function admin_listar_uploads(text,text) from public, anon;
grant execute on function admin_listar_uploads(text,text) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 3.4: a etapa "arquivos enviados" de v_pendencias passa a exigir a
-- QUANTIDADE certa de logo, nao so "pelo menos um arquivo do tipo".
-- ---------------------------------------------------------------------
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
  -- 12. arquivos enviados — entra na lista quem a cota exige (logo em
  -- quantidade, ou pelo menos um dos 4 tipos boolean). Concluida
  -- quando a quantidade certa de logo E todos os tipos boolean tem
  -- linha em patrocinador_uploads (nao precisa estar aprovado —
  -- "enviou" ja fecha a etapa; aprovacao e outro controle, na tela de
  -- revisao)
  select p.evento_id, 'patrocinador', p.id, null, p.empresa,
         'arquivos_enviados', p.created_at,
         case when (
                select count(*) from patrocinador_uploads u
                where u.patrocinador_id = p.id and u.tipo = 'logo'
              ) >= greatest(coalesce(co.upload_logo_qtd,0), 0)
              and (
                select count(distinct u.tipo) from patrocinador_uploads u
                where u.patrocinador_id = p.id and u.tipo = any(v_req.tipos_bool)
              ) >= coalesce(array_length(v_req.tipos_bool, 1), 0)
              then (select max(u.enviado_em) from patrocinador_uploads u
                    where u.patrocinador_id = p.id
                      and (u.tipo = any(v_req.tipos_bool) or u.tipo = 'logo'))
              else null end,
         coalesce(co.prazo_upload, e2.prazo_upload_padrao),
         null
  from patrocinadores p
  join cotas co on co.id = p.cota_id
  join eventos e2 on e2.id = p.evento_id
  cross join lateral (
    select array_remove(array[
      case when co.upload_banner then 'banner' end,
      case when co.upload_arte_revista then 'arte_revista' end,
      case when co.upload_apresentacao then 'apresentacao' end,
      case when co.upload_video then 'video' end
    ], null) as tipos_bool
  ) v_req
  where p.status = 'ativo'
    and (coalesce(co.upload_logo_qtd,0) > 0 or coalesce(array_length(v_req.tipos_bool, 1), 0) > 0)
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

-- so agora, com as duas views ja redefinidas sem referenciar a coluna
-- velha, o DROP nao esbarra em dependencia
alter table cotas drop column if exists upload_logo;
