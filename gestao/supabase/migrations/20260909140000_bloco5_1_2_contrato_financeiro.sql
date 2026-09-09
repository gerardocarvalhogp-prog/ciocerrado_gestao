-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Bloco 5.1 (contrato) + 5.2 (financeiro por patrocinador/evento).
--
-- O QUE JA EXISTIA (conferido antes de desenhar isto — ver relatorio)
--
-- "O que a cota da direito" ja e' quase todo coberto: quartos por tipo
-- (cota_quartos), vagas de mesa redonda/jantar-do-evento-grande
-- (vagas_mesa_redonda, compartilhado entre os tipos de sessao — nao
-- existe "vagas_jantar" separado porque sessoes.tipo='jantar' ja usa o
-- mesmo numero), e os 5 booleans de upload que o Bloco 3 vai trocar por
-- quantidade. So faltava o VALOR — nem da cota (referencia) nem do
-- contrato de cada empresa (o que realmente foi fechado).
--
-- Por isso este bloco so acrescenta:
--   cotas.valor_sugerido       — preco de tabela da cota, so referencia
--   patrocinadores.valor_contratado, status_pagamento, data_vencimento,
--     data_pagamento, observacao_pagamento — o contrato de fato
--
-- "Vencido" NAO e um status gravado — computado (status em
-- aberto/parcial + vencimento no passado), mesmo padrao que
-- v_pendencias ja usa pra fatura_paga. Gravar "vencido" trava e fica
-- errado no dia seguinte se ninguem lembrar de atualizar.
-- =====================================================================

set search_path = gestao, public;

alter table cotas add column if not exists valor_sugerido numeric(12,2);

alter table patrocinadores add column if not exists valor_contratado numeric(12,2);
alter table patrocinadores add column if not exists status_pagamento text not null default 'aberto';
alter table patrocinadores drop constraint if exists patrocinadores_status_pagamento_check;
alter table patrocinadores add constraint patrocinadores_status_pagamento_check
  check (status_pagamento in ('aberto','parcial','pago'));
alter table patrocinadores add column if not exists data_vencimento date;
alter table patrocinadores add column if not exists data_pagamento date;
alter table patrocinadores add column if not exists observacao_pagamento text;

comment on column patrocinadores.status_pagamento is
  '"vencido" nao e um valor aqui — e calculado (aberto/parcial + data_vencimento no passado). Ver admin_listar_financeiro_cotas.';

-- ---------------------------------------------------------------------
-- 5.1 — cotas ganham valor_sugerido. Assinatura ganha um parametro
-- novo (trailing, com default) -> exige DROP, senao cria uma segunda
-- funcao ao lado da de 17 parametros.
-- ---------------------------------------------------------------------
drop function if exists admin_salvar_cota(text,text,integer,jsonb,integer,boolean,boolean,date,integer,integer,boolean,boolean,boolean,boolean,boolean,boolean,date);

create function admin_salvar_cota(
  p_evento_slug text, p_nome text, p_ordem integer,
  p_quartos jsonb DEFAULT '{}'::jsonb, p_vagas_mesa integer DEFAULT 0,
  p_reuniao boolean DEFAULT false, p_jantar boolean DEFAULT false,
  p_prazo_indicacao date DEFAULT NULL::date, p_janela_horas integer DEFAULT NULL::integer,
  p_limite_indicacoes integer DEFAULT NULL::integer,
  p_escolhe_convidados boolean DEFAULT true,
  p_upload_logo boolean DEFAULT false, p_upload_banner boolean DEFAULT false,
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
                     upload_apresentacao, upload_video, prazo_upload,
                     valor_sugerido)
  values (v_evento, trim(p_nome), v_ordem, coalesce(p_vagas_mesa,0),
          p_reuniao, p_jantar, 0, 'duplo', p_prazo_indicacao, p_janela_horas,
          p_limite_indicacoes, coalesce(p_escolhe_convidados, true),
          coalesce(p_upload_logo,false), coalesce(p_upload_banner,false),
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
    upload_logo = excluded.upload_logo,
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

revoke execute on function admin_salvar_cota(text,text,integer,jsonb,integer,boolean,boolean,date,integer,integer,boolean,boolean,boolean,boolean,boolean,boolean,date,numeric) from public, anon;
grant execute on function admin_salvar_cota(text,text,integer,jsonb,integer,boolean,boolean,date,integer,integer,boolean,boolean,boolean,boolean,boolean,boolean,date,numeric) to authenticated, service_role;

drop function if exists admin_listar_cotas(text);

create function admin_listar_cotas(p_evento_slug text) returns table (
  id uuid, nome text, ordem_prioridade integer, quartos jsonb,
  total_quartos bigint, vagas_mesa_redonda integer,
  tem_reuniao_exclusiva boolean, tem_jantar boolean,
  patrocinadores bigint, lista_patrocinadores jsonb,
  prazo_indicacao date, janela_horas integer, limite_indicacoes integer,
  escolhe_convidados boolean,
  upload_logo boolean, upload_banner boolean, upload_arte_revista boolean,
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
           c.upload_logo, c.upload_banner, c.upload_arte_revista,
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
-- 5.2 — financeiro da cota (contrato), separado do financeiro de
-- adicionais que admin_financeiro_resumo/admin_listar_faturas ja
-- cobrem.
-- ---------------------------------------------------------------------
create or replace function admin_definir_pagamento_patrocinador(
  p_id uuid, p_valor_contratado numeric DEFAULT NULL::numeric,
  p_status_pagamento text DEFAULT NULL::text,
  p_data_vencimento date DEFAULT NULL::date,
  p_data_pagamento date DEFAULT NULL::date,
  p_observacao text DEFAULT NULL::text
) returns jsonb language plpgsql security definer
set search_path to 'gestao', 'public' as $$
begin
  perform _exige_admin();

  if p_status_pagamento is not null and p_status_pagamento not in ('aberto','parcial','pago') then
    raise exception 'Status de pagamento invalido: %', p_status_pagamento using errcode='22023';
  end if;
  if not exists (select 1 from patrocinadores where id = p_id) then
    raise exception 'Patrocinador nao encontrado' using errcode='P0002';
  end if;

  update patrocinadores set
    valor_contratado = coalesce(p_valor_contratado, valor_contratado),
    status_pagamento = coalesce(p_status_pagamento, status_pagamento),
    data_vencimento = coalesce(p_data_vencimento, data_vencimento),
    -- pagamento e' o unico que aceita apagar (voltar pra aberto por
    -- engano precisa poder desfazer a data tambem) — por isso usa o
    -- proprio p_data_pagamento sem coalesce quando o status muda pra
    -- 'aberto'
    data_pagamento = case
      when p_status_pagamento = 'aberto' then null
      else coalesce(p_data_pagamento, data_pagamento) end,
    observacao_pagamento = coalesce(p_observacao, observacao_pagamento)
  where id = p_id;

  return jsonb_build_object('ok', true);
end;
$$;

revoke execute on function admin_definir_pagamento_patrocinador(uuid,numeric,text,date,date,text) from public, anon;
grant execute on function admin_definir_pagamento_patrocinador(uuid,numeric,text,date,date,text) to authenticated, service_role;

create or replace function admin_financeiro_cotas_resumo(p_evento_slug text)
returns jsonb language plpgsql stable security definer
set search_path to 'gestao', 'public' as $$
declare v jsonb;
begin
  perform _exige_staff();
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
$$;

revoke execute on function admin_financeiro_cotas_resumo(text) from public, anon;
grant execute on function admin_financeiro_cotas_resumo(text) to authenticated, service_role;

create or replace function admin_listar_financeiro_cotas(p_evento_slug text)
returns table (
  id uuid, empresa text, cota text, valor_contratado numeric,
  status_pagamento text, data_vencimento date, data_pagamento date,
  observacao_pagamento text, vencido boolean
)
language plpgsql stable security definer
set search_path to 'gestao', 'public' as $$
begin
  perform _exige_staff();
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
$$;

revoke execute on function admin_listar_financeiro_cotas(text) from public, anon;
grant execute on function admin_listar_financeiro_cotas(text) to authenticated, service_role;
