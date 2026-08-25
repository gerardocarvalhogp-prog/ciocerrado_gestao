-- =====================================================================
-- CORRECAO PARA O BANCO HOSPEDADO  ·  indicacao no PERFIL e porte
--
-- NAO e uma migration. O banco remoto seguiu um caminho proprio e as
-- migrations locais NAO devem ser aplicadas la (ver LEIA-ME.md desta
-- pasta). Este arquivo cria um helper e troca UMA funcao.
--
-- Corresponde a migration local 20260824102300_indicacao_e_porte.sql —
-- corpo identico, so o cabecalho muda.
--
-- O QUE MUDA (conferido no dump de 24/08/2026)
--
-- A versao remota de `patro_convidados_disponiveis` ordena por
-- `g.empresa, g.nome`. A primeira camada da regra de alocacao — "se o
-- patrocinador indicou a pessoa no PERFIL, ela vai para a mesa dele" —
-- nao esta implementada, embora a coluna
-- `participantes.indicado_por_patrocinador_id` exista e ja tenha dado
-- (3 indicados na base hospedada).
--
-- A segunda camada, porte, tambem entra: ordenar
-- `participante_perfil.faturamento` como TEXTO joga "Acima de 5
-- Bilhões" para o fim da lista, atras de "Até 500 Milhões".
--
-- ATENCAO · o retorno muda, entao ha DROP
--
-- Remoto devolve  (participante_id, nome, empresa, cargo, segmento)
-- Passa a devolver(participante_id, nome, empresa, cargo, segmento,
--                  indicado_por_mim)
--
-- E superset: `segmento` continua la. O portal.html usa so
-- participante_id, nome, empresa e cargo — nao quebra.
--
-- Como a funcao e recriada, ela nasce sem o ACL antigo; os grants no
-- fim do arquivo reafirmam o fechamento feito por 01-fechar-anon.sql.
--
-- APLICAR
--   supabase db query --linked -f supabase/remoto/03-indicacao-e-porte.sql
--
-- ROLLBACK: o corpo anterior esta neste LEIA-ME e no dump; recriar com
-- `order by g.empresa, g.nome` e sem a coluna indicado_por_mim.
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
