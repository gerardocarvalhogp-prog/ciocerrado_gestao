-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- funcoes-etiquetas.sql  ·  etiquetas com e sem hospedagem
--
-- Rodar DEPOIS de funcoes-prospeccao.sql.
--
-- Problema: a etiqueta saia de ocupantes, e ocupante so existe depois
-- do rooming. Evento sem hospedagem (jantar, encontro de um dia) nao
-- tem rooming nenhum, entao a lista vinha vazia.
--
-- Agora a etiqueta vem de tres fontes, nesta ordem de prioridade:
--   1. ocupantes de quarto      -> tem apto
--   2. participante sem reserva -> sem apto
--   3. usuario de patrocinador  -> sem apto, quando a empresa nao tem quarto
-- =====================================================================

set search_path = gestao, public;

-- =====================================================================
-- 1. VIEW UNIFICADA
-- =====================================================================

create or replace view v_etiquetas as

-- (1) quem esta num quarto
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
  end                                   as categoria,
  'quarto'::text                        as origem
from ocupantes o
join reservas r        on r.id = o.reserva_id and r.status <> 'cancelado'
left join quartos q    on q.id = r.quarto_id
left join patrocinadores p on p.id = r.patrocinador_id
left join participantes pa on pa.id = r.participante_id
left join gestores g   on g.id = pa.gestor_id

union all

-- (2) participante aprovado que nao tem reserva nenhuma.
-- E o caso do evento sem hospedagem, mas cobre tambem quem ainda nao
-- preencheu o rooming num evento que tem.
select
  pa.evento_id,
  null::text,
  g.nome,
  g.empresa,
  'PROTAGONISTA'::text,
  'inscricao'::text
from participantes pa
join gestores g on g.id = pa.gestor_id
where pa.status = 'aprovado'
  and not exists (
    select 1 from reservas r
    where r.participante_id = pa.id and r.status <> 'cancelado')

union all

-- (3) equipe do patrocinador que nao tem quarto.
-- Se a empresa tem reserva, os ocupantes sao a verdade e esta fonte
-- fica de fora, para nao duplicar a mesma pessoa.
select
  p.evento_id,
  null::text,
  coalesce(u.nome, split_part(u.email, '@', 1)),
  p.empresa,
  'PATROCINADOR'::text,
  'patrocinador'::text
from usuarios_patrocinador u
join patrocinadores p on p.id = u.patrocinador_id
where u.ativo
  and p.status = 'ativo'
  and not exists (
    select 1 from reservas r
    where r.patrocinador_id = p.id and r.status <> 'cancelado');

-- =====================================================================
-- 2. FUNCAO COM FILTRO
-- =====================================================================

create or replace function admin_etiquetas(
  p_evento_slug text,
  p_categoria text default null,
  p_origem text default null       -- quarto | inscricao | patrocinador
) returns table (apto text, nome text, empresa text,
                 categoria text, origem text)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();
  return query
    select v.apto, v.nome, v.empresa, v.categoria, v.origem
    from v_etiquetas v
    join eventos e on e.id = v.evento_id and e.slug = p_evento_slug
    where (p_categoria is null or v.categoria = p_categoria)
      and (p_origem is null or v.origem = p_origem)
    -- ordem de impressao: primeiro quem tem quarto, por numero; depois
    -- quem nao tem, em ordem alfabetica
    order by
      (v.apto is null),
      nullif(regexp_replace(coalesce(v.apto,''),'[^0-9]','','g'),'')::int nulls last,
      v.categoria, v.nome;
end;
$$;

-- Quantas etiquetas de cada tipo, para a tela avisar antes de imprimir.
create or replace function admin_etiquetas_resumo(p_evento_slug text)
returns table (origem text, categoria text, total bigint)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();
  return query
    select v.origem, v.categoria, count(*)
    from v_etiquetas v
    join eventos e on e.id = v.evento_id and e.slug = p_evento_slug
    group by v.origem, v.categoria
    order by v.origem, v.categoria;
end;
$$;

grant execute on function
  admin_etiquetas(text, text, text),
  admin_etiquetas_resumo(text)
to authenticated;

-- Assinatura antiga com 2 parametros ficaria orfa ao lado da nova.
drop function if exists admin_etiquetas(text, text);
