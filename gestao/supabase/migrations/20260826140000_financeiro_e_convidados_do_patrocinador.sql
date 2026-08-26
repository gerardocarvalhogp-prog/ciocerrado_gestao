-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- O patrocinador passa a ver a propria conta e quem ja esta confirmado.
--
-- 1. FINANCEIRO
--
-- A fatura do patrocinador ja existia e era calculada — quarto extra,
-- transfer, entrega de brinde no quarto. So que ele nao tinha como
-- ve-la: `admin_listar_faturas` exige staff. A empresa descobria o
-- valor quando a organizacao mandava, e cada duvida virava e-mail.
--
-- Mostrar a fatura junto com o item que a gerou responde a pergunta
-- seguinte antes que ela seja feita: nao e "quanto deu", e "por que
-- deu isso".
--
-- 2. CONVIDADOS CONFIRMADOS
--
-- Quem patrocina quer saber quem vai estar la — e isso muda a decisao
-- de quem levar para a mesa. A lista sai so com quem esta APROVADO e
-- com CONTRATO ASSINADO: convidado que ainda pode nao vir nao e
-- presenca confirmada, e prometer presenca que nao se cumpre e pior do
-- que nao informar.
--
-- SEM E-MAIL E SEM TELEFONE, de proposito. O patrocinador ve quem vem,
-- de onde e de que empresa — o suficiente para decidir a mesa. Contato
-- ele recebe de quem ele efetivamente escolheu, pelo mailing da sessao.
-- Entregar a agenda inteira de 130 executivos a 61 empresas nao e o
-- que ninguem combinou ao se inscrever.
-- =====================================================================

set search_path = gestao, public;

-- ---------------------------------------------------------------------
-- 1. A CONTA DA EMPRESA
-- ---------------------------------------------------------------------
create or replace function patro_minha_fatura(p_patrocinador_id uuid)
returns jsonb language plpgsql stable security definer
set search_path = gestao, public as $$
declare v_out jsonb;
begin
  perform _exige_patrocinador(p_patrocinador_id);

  select jsonb_build_object(
    'fatura_id', f.id,
    'total',     f.total,
    'status',    f.status,
    'vencimento', f.vencimento,
    'emitida_em', f.emitida_em,
    'paga_em',    f.paga_em,
    'observacao', f.observacao,
    'itens', coalesce((
      select jsonb_agg(jsonb_build_object(
               'descricao',   fi.descricao,
               'quantidade',  fi.quantidade,
               'valor_unit',  fi.valor_unit,
               'valor_total', fi.valor_total)
             order by fi.descricao)
      from fatura_itens fi where fi.fatura_id = f.id), '[]'::jsonb))
  into v_out
  from faturas f
  where f.patrocinador_id = p_patrocinador_id
    and f.status <> 'cancelada'
  -- emitida na frente da estimada: e a que tem valor combinado
  order by case f.status when 'emitida' then 1 when 'paga' then 2 else 3 end
  limit 1;

  -- Sem fatura nao e erro: quem nao comprou quarto extra, nao pediu
  -- entrega no quarto e nao tem transfer simplesmente nao deve nada.
  return coalesce(v_out, jsonb_build_object(
    'total', 0, 'status', 'sem_cobranca', 'itens', '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------
-- 2. QUEM JA ESTA CONFIRMADO
-- ---------------------------------------------------------------------
create or replace function patro_convidados_confirmados(
  p_patrocinador_id uuid,
  p_termo text default null,
  p_cidade text default null,
  p_estado text default null,
  p_segmento text default null,
  p_limite int default 500,
  p_offset int default 0
) returns table (
  nome text,
  empresa text,
  cargo text,
  cidade text,
  estado text,
  segmento text,
  porte text,
  ja_e_meu_convidado boolean
)
language plpgsql stable security definer
set search_path = gestao, public as $$
declare v_evento uuid; v_termo text;
begin
  perform _exige_patrocinador(p_patrocinador_id);

  select evento_id into v_evento from patrocinadores where id = p_patrocinador_id;

  -- normaliza igual ao resto do sistema: minusculo, sem acento
  v_termo := nullif(trim(coalesce(p_termo,'')), '');

  return query
    select g.nome, g.empresa, g.cargo, g.cidade, g.estado, g.segmento,
           pp.faturamento,
           exists (
             select 1 from sessao_convidados sc
             join sessoes s on s.id = sc.sessao_id
             where sc.participante_id = pa.id
               and sc.status = 'confirmado'
               and s.patrocinador_id = p_patrocinador_id
           )
    from participantes pa
    join gestores g on g.id = pa.gestor_id
    join contratos c on c.participante_id = pa.id and c.status = 'assinado'
    left join participante_perfil pp on pp.participante_id = pa.id
    where pa.evento_id = v_evento
      and pa.status = 'aprovado'
      and (p_cidade   is null or lower(g.cidade)   = lower(p_cidade))
      and (p_estado   is null or lower(g.estado)   = lower(p_estado))
      and (p_segmento is null or lower(g.segmento) = lower(p_segmento))
      and (v_termo is null
           or norm_doc(g.nome)    like '%' || norm_doc(v_termo) || '%'
           or norm_doc(g.empresa) like '%' || norm_doc(v_termo) || '%')
    order by g.empresa, g.nome
    limit greatest(coalesce(p_limite, 500), 1)
    offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

-- As opcoes dos filtros saem do que existe, nao de lista fixa: cidade
-- nova aparece sozinha quando o primeiro inscrito de la e aprovado.
create or replace function patro_filtros_convidados(p_patrocinador_id uuid)
returns jsonb language plpgsql stable security definer
set search_path = gestao, public as $$
declare v_evento uuid; v_out jsonb;
begin
  perform _exige_patrocinador(p_patrocinador_id);
  select evento_id into v_evento from patrocinadores where id = p_patrocinador_id;

  with base as (
    select g.cidade, g.estado, g.segmento
    from participantes pa
    join gestores g on g.id = pa.gestor_id
    join contratos c on c.participante_id = pa.id and c.status = 'assinado'
    where pa.evento_id = v_evento and pa.status = 'aprovado'
  )
  select jsonb_build_object(
    'cidades',  coalesce((select jsonb_agg(distinct cidade order by cidade)
                          from base where nullif(trim(cidade),'') is not null), '[]'::jsonb),
    'estados',  coalesce((select jsonb_agg(distinct estado order by estado)
                          from base where nullif(trim(estado),'') is not null), '[]'::jsonb),
    'segmentos',coalesce((select jsonb_agg(distinct segmento order by segmento)
                          from base where nullif(trim(segmento),'') is not null), '[]'::jsonb),
    'total',    (select count(*) from base))
  into v_out;

  return v_out;
end;
$$;

-- ---------------------------------------------------------------------
-- 3. PERMISSAO
-- ---------------------------------------------------------------------
revoke execute on function patro_minha_fatura(uuid) from public, anon;
revoke execute on function patro_convidados_confirmados(uuid, text, text, text, text, int, int) from public, anon;
revoke execute on function patro_filtros_convidados(uuid) from public, anon;
grant execute on function patro_minha_fatura(uuid) to authenticated, service_role;
grant execute on function patro_convidados_confirmados(uuid, text, text, text, text, int, int) to authenticated, service_role;
grant execute on function patro_filtros_convidados(uuid) to authenticated, service_role;
