-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Escopo de staff por evento nas funcoes que tinham ficado de fora.
--
-- Achado dos testes 13, 14 e 23 (05/10/2026), decisao do organizador:
-- corrigir. 20260831160000/20260831180000 (testes 10 e 11) fizeram staff
-- enxergar so o evento associado em admin_eventos; estas sete continuavam
-- checando so _exige_staff() — staff de OUTRO evento lia contrato e
-- pagamento das cotas, cotas, patrocinadores, quartos e o relatorio do
-- Lounge, e bloqueava/desbloqueava quarto. Admin continua vendo tudo
-- (_exige_staff_do_evento libera admin na hora).
--
-- As seis que recebem p_evento_slug trocam so a linha da guarda. Em
-- admin_definir_status_quarto (recebe id de quarto) o evento e lido do
-- quarto e a guarda de escopo entra logo depois — _exige_staff() fica
-- na primeira linha como sempre.
--
-- O teste 23 varre o catalogo: funcao com p_evento_slug que so chama
-- _exige_staff() volta a aparecer la se alguma migration futura
-- esquecer.
-- =====================================================================

set search_path = gestao, public;

CREATE OR REPLACE FUNCTION gestao.admin_financeiro_cotas_resumo(p_evento_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
declare v jsonb;
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);
  select jsonb_build_object(
    'contratado', coalesce(sum(p.valor_contratado),0),
    'pago', coalesce(sum(p.valor_contratado) filter (where p.status_pagamento = 'pago'),0),
    'em_aberto', coalesce(sum(p.valor_contratado) filter (where p.status_pagamento <> 'pago'),0),
    'vencido', coalesce(sum(p.valor_contratado) filter (
      where p.status_pagamento <> 'pago' and p.data_vencimento < current_date),0),
    'qtd_vencidas', count(*) filter (
      where p.status_pagamento <> 'pago' and p.data_vencimento < current_date)
  ) into v
  from patrocinadores p
  join eventos e on e.id = p.evento_id and e.slug = p_evento_slug
  where p.status = 'ativo';
  return v;
end;
$function$;

CREATE OR REPLACE FUNCTION gestao.admin_listar_cotas(p_evento_slug text)
 RETURNS TABLE(id uuid, nome text, ordem_prioridade integer, quartos jsonb, total_quartos bigint, vagas_mesa_redonda integer, tem_reuniao_exclusiva boolean, tem_jantar boolean, patrocinadores bigint, lista_patrocinadores jsonb, prazo_indicacao date, janela_horas integer, limite_indicacoes integer, escolhe_convidados boolean, upload_logo_qtd integer, upload_banner boolean, upload_arte_revista boolean, upload_apresentacao boolean, upload_video boolean, prazo_upload date, valor_sugerido numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);
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
$function$;

CREATE OR REPLACE FUNCTION gestao.admin_listar_financeiro_cotas(p_evento_slug text)
 RETURNS TABLE(id uuid, empresa text, cota text, valor_contratado numeric, status_pagamento text, data_vencimento date, data_pagamento date, observacao_pagamento text, vencido boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);
  return query
    select p.id, p.empresa, c.nome, p.valor_contratado,
           p.status_pagamento, p.data_vencimento, p.data_pagamento,
           p.observacao_pagamento,
           p.status_pagamento <> 'pago' and p.data_vencimento < current_date
    from patrocinadores p
    left join cotas c on c.id = p.cota_id
    join eventos e on e.id = p.evento_id and e.slug = p_evento_slug
    where p.status = 'ativo'
    order by c.ordem_prioridade nulls last, p.empresa;
end;
$function$;

CREATE OR REPLACE FUNCTION gestao.admin_listar_patrocinadores(p_evento_slug text)
 RETURNS TABLE(id uuid, empresa_id uuid, empresa text, cnpj text, segmento text, site text, resumo text, o_que_vende text, natureza text, cidade text, estado text, cota text, ordem integer, quartos_extras integer, vagas_mesa_override integer, status text, fechado_em timestamp with time zone, enriquecido_em timestamp with time zone, usuarios bigint, reservas bigint, lounge text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);
  return query
    select p.id, p.empresa_id, e.nome, e.cnpj, e.segmento,
           e.site, e.resumo, e.o_que_vende, e.natureza,
           e.cidade, e.estado,
           c.nome, c.ordem_prioridade, p.quartos_extras_cota,
           p.vagas_mesa_override, p.status, p.fechado_em, p.enriquecido_em,
           (select count(*) from usuarios_patrocinador u
             where u.empresa_id = p.empresa_id and u.ativo),
           (select count(*) from reservas r
             where r.patrocinador_id = p.id and r.status <> 'cancelado'),
           p.lounge
    from patrocinadores p
    join empresas e on e.id = p.empresa_id
    left join cotas c on c.id = p.cota_id
    join eventos ev on ev.id = p.evento_id and ev.slug = p_evento_slug
    order by c.ordem_prioridade nulls last, e.nome;
end;
$function$;

CREATE OR REPLACE FUNCTION gestao.admin_listar_quartos_individual(p_evento_slug text, p_busca text DEFAULT NULL::text)
 RETURNS TABLE(id uuid, numero text, tipo text, capacidade integer, status text, bloco text, andar text, corredor text, categoria text, finalidade text, reserva_id uuid, ocupado_por text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
declare v_termo text;
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);
  v_termo := nullif(trim(coalesce(p_busca,'')), '');

  return query
    select q.id, q.numero, q.tipo, q.capacidade, q.status,
           q.bloco, q.andar, q.corredor, q.categoria, q.finalidade,
           r.id,
           coalesce(r.ocupado_por, p.empresa, g.empresa, r.rotulo)
    from quartos q
    join eventos e on e.id = q.evento_id and e.slug = p_evento_slug
    left join reservas r on r.quarto_id = q.id and r.status <> 'cancelado'
    left join patrocinadores p on p.id = r.patrocinador_id
    left join participantes pa on pa.id = r.participante_id
    left join gestores g on g.id = pa.gestor_id
    where v_termo is null
       or q.numero ilike '%'||v_termo||'%'
       or coalesce(q.bloco,'') ilike '%'||v_termo||'%'
    order by
      nullif(regexp_replace(coalesce(q.numero,''),'[^0-9]','','g'),'')::int nulls last,
      q.numero;
end;
$function$;

CREATE OR REPLACE FUNCTION gestao.admin_rel_lounge(p_evento_slug text)
 RETURNS TABLE(lounge text, empresa text, cota text, segmento text, site text, contato_nome text, contato_email text, contato_telefone text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);
  return query
    select p.lounge, p.empresa, c.nome, p.segmento, p.site,
           u.nome, u.email, u.telefone
    from patrocinadores p
    join eventos e on e.id = p.evento_id and e.slug = p_evento_slug
    left join cotas c on c.id = p.cota_id
    left join usuarios_patrocinador u on u.empresa_id = p.empresa_id and u.ativo
    where p.lounge is not null and p.status = 'ativo'
    order by p.lounge, p.empresa, u.nome nulls last;
end;
$function$;

CREATE OR REPLACE FUNCTION gestao.admin_definir_status_quarto(p_id uuid, p_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
declare
  v_evento uuid; v_status_atual text; v_ocupado boolean;
begin
  perform _exige_staff();

  if p_status not in ('disponivel', 'bloqueado') then
    raise exception 'Status invalido: %. Use disponivel ou bloqueado — reservado e automatico, via atribuicao de quarto.', p_status
      using errcode = '22023';
  end if;

  select evento_id, status into v_evento, v_status_atual from quartos where id = p_id;
  if v_evento is null then
    raise exception 'Quarto nao encontrado' using errcode = 'P0002';
  end if;
  perform _exige_staff_do_evento(v_evento);

  select exists(select 1 from reservas r
                where r.quarto_id = p_id and r.status <> 'cancelado')
    into v_ocupado;

  if v_ocupado then
    raise exception 'Este quarto esta atribuido a uma reserva — libere a atribuicao antes de mudar o status'
      using errcode = '55000';
  end if;

  update quartos set status = p_status where id = p_id;

  return jsonb_build_object('ok', true, 'status', p_status);
end;
$function$;
