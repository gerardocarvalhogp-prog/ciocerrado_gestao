-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Indicacao no PERFIL e ordem de porte na lista de convidados.
--
-- Duas camadas da regra de alocacao estavam so meio implementadas em
-- `patro_convidados_disponiveis`.
--
-- CAMADA 1 · INDICACAO
--
-- "Se o patrocinador indicou a pessoa no PERFIL, ela vai para a mesa
-- dele." A coluna `participantes.indicado_por_patrocinador_id` ja
-- existe; faltava a lista usa-la. Aqui ela vira a primeira chave de
-- ordenacao e ganha uma coluna propria (`indicado_por_mim`) para a tela
-- poder marcar quem e quem.
--
-- O coalesce nao e decoracao: para quem ninguem indicou a coluna e
-- nula, e `null = uuid` da NULL, nao false. Em `desc` o Postgres ordena
-- NULL, true, false — os NAO indicados subiriam acima dos indicados,
-- invertendo exatamente a regra que se quer implementar.
--
-- CAMADA 2 · PORTE
--
-- `order by pp.faturamento desc` ordenava TEXTO. Os valores vem do
-- Sympla como faixa escrita:
--
--   Acima de 5 Bilhões
--   De 3,1 Bilhões a 5 Bilhões
--   De 1,1 Bilhões a 3 Bilhões
--   Até 500 Milhões
--
-- Em ordem alfabetica decrescente, "Acima de 5 Bilhões" — a MAIOR
-- faixa — cai em ultimo, atras de "Até 500 Milhões". A ordem de porte
-- ficava ao contrario justamente no topo, que e onde ela importa.
--
-- `_porte_faturamento` le a faixa e devolve o teto em milhoes, para a
-- ordenacao ser numerica. Nao ha lista fixa de faixas: se o Sympla
-- mudar o texto, continua funcionando enquanto houver numero e a
-- palavra "milh"/"bilh".
--
-- ORDEM: depois de 102100 (trava do anon). Aqui ha DROP, entao a funcao
-- nasce de novo — os grants explicitos no fim garantem que ela nao
-- volte aberta para anon.
-- =====================================================================

set search_path = gestao, public;

-- ---------------------------------------------------------------------
-- 1. PORTE A PARTIR DA FAIXA ESCRITA
-- ---------------------------------------------------------------------
create or replace function _porte_faturamento(p_texto text)
returns numeric language sql immutable as $$
  select case when p_texto is null or btrim(p_texto) = '' then 0 else
    -- pega TODOS os pares numero+unidade e fica com o maior: numa faixa
    -- como "De 500 Milhões a 1,1 Bilhões" o que ordena e o teto.
    coalesce((
      select max(replace(m[1], ',', '.')::numeric
                 * case when m[2] = 'bilh' then 1000 else 1 end)
      from regexp_matches(lower(p_texto),
             '([0-9]+(?:[.,][0-9]+)?)\s*(bilh|milh)', 'g') as m
    ), 0)
    -- "Acima de 5 Bilhões" e "De 3,1 a 5 Bilhões" tem o mesmo teto; a
    -- faixa aberta e a maior das duas e precisa desempatar para cima.
    + case when lower(p_texto) like 'acima%' then 1 else 0 end
  end;
$$;

comment on function _porte_faturamento(text) is
  'Faixa de faturamento escrita (Sympla) -> teto em milhoes, para ordenar por porte.';

-- ---------------------------------------------------------------------
-- 2. LISTA DE CONVIDADOS DISPONIVEIS
--
-- DROP porque o retorno muda: entram `segmento` (materia-prima da
-- camada 3, afinidade) e `indicado_por_mim`. O front nao quebra — usa
-- participante_id, nome, empresa e cargo, e ignora o resto.
-- ---------------------------------------------------------------------
drop function if exists patro_convidados_disponiveis(uuid);

create function patro_convidados_disponiveis(p_sessao_id uuid)
returns table (
  participante_id uuid,
  nome text,
  empresa text,
  cargo text,
  segmento text,
  indicado_por_mim boolean
)
language plpgsql stable security definer set search_path = gestao, public as $$
declare s record;
begin
  select * into s from sessoes where id = p_sessao_id;
  if s.id is null then
    raise exception 'Sessao nao encontrada.' using errcode = 'P0002';
  end if;
  perform _exige_patrocinador(s.patrocinador_id);

  return query
  select
    pa.id, g.nome, g.empresa, g.cargo, g.segmento,
    coalesce(pa.indicado_por_patrocinador_id = s.patrocinador_id, false)
      as indicado_por_mim
  from participantes pa
  join gestores g on g.id = pa.gestor_id
  left join participante_perfil pp on pp.participante_id = pa.id
  where pa.evento_id = s.evento_id
    and pa.status = 'aprovado'
    -- quem ja foi escolhido por qualquer empresa some da lista de todo
    -- mundo, dentro do mesmo tipo de sessao — e o que a tela promete
    and not exists (
      select 1 from sessao_convidados sc
      join sessoes s2 on s2.id = sc.sessao_id
      where sc.participante_id = pa.id
        and sc.status = 'confirmado'
        and s2.evento_id = s.evento_id
        and s2.tipo = s.tipo
    )
  order by
    coalesce(pa.indicado_por_patrocinador_id = s.patrocinador_id, false) desc,
    _porte_faturamento(pp.faturamento) desc,
    g.nome;
end;
$$;

-- ---------------------------------------------------------------------
-- 3. PERMISSAO
--
-- Explicito porque a funcao acabou de nascer: nao herda o ACL da
-- anterior e depende do default privilege do schema, que ja foi
-- fechado em 102100 mas nao custa reafirmar.
-- ---------------------------------------------------------------------
revoke execute on function patro_convidados_disponiveis(uuid) from public, anon;
revoke execute on function _porte_faturamento(text) from public, anon;
grant execute on function patro_convidados_disponiveis(uuid) to authenticated, service_role;
grant execute on function _porte_faturamento(text) to authenticated, service_role;
