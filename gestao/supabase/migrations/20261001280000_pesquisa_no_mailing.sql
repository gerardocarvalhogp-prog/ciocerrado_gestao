-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Pedido do organizador em 01/10/2026: "No mail, leva também os dados
-- da pesquisa" — o Mailing list (admin_rel_mailing) e a Pesquisa de
-- perfil (admin_rel_pesquisa) eram dois relatorios separados, mas a
-- pesquisa ja tem TODO o dado do mailing (nome/empresa/cargo/email/
-- telefone/segmento/estado/cnpj) MAIS faturamento, orcamento de TI,
-- areas de investimento etc. So faltava o tipo de ingresso (g.perfil —
-- "CLIENTE", "CONVIDADO CIO CERRADO"...) que so o mailing tinha.
--
-- IMPORTANTE, pra nao prometer o que o sistema nao faz: a pesquisa NAO
-- vem de uma API do Sympla acessivel por aqui (gotcha documentado no
-- CLAUDE.md — a API do Sympla nao e alcancavel de dentro do ambiente
-- do Claude). Ela entra pelo export .xlsx que o organizador sobe na
-- aba "Pesquisa de perfil" (admin_importar_pesquisa, ja existente).
-- Esta migration so' junta o que JA foi importado; nao importa nada
-- novo.
--
-- admin_rel_pesquisa muda de assinatura (ganha perfil_ingresso) —
-- precisa de DROP antes do CREATE, create or replace nao troca o
-- formato de retorno.
-- =====================================================================

set search_path = gestao, public;

drop function if exists admin_rel_pesquisa(text, integer, integer);

create function admin_rel_pesquisa(p_evento_slug text, p_limite integer DEFAULT 500, p_offset integer DEFAULT 0)
returns table(
  perfil_ingresso text, nome text, empresa text, cargo text, email text, telefone text,
  segmento text, estado text, cnpj text, faturamento text, orcamento_ti text,
  colaboradores text, colaboradores_ti text, erp_atual text, dispositivos text,
  terceirizados text, consentimento_lgpd boolean, investimentos jsonb, perfil jsonb,
  respondeu boolean, total_geral bigint
)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);
  return query
    select g.perfil, g.nome, g.empresa, g.cargo, g.email, g.telefone,
           g.segmento, g.estado, g.cnpj,
           pp.faturamento, pp.orcamento_ti, pp.colaboradores,
           pp.colaboradores_ti, pp.erp_atual,
           pp.respostas ->> 'dispositivos',
           pp.respostas ->> 'terceirizados',
           pp.consentimento_lgpd,
           coalesce(pp.respostas -> 'investimentos', '{}'::jsonb),
           coalesce(pp.respostas -> 'perfil', '{}'::jsonb),
           (pp.participante_id is not null),
           count(*) over ()
    from participantes pa
    join gestores g on g.id = pa.gestor_id
    join eventos  e on e.id = pa.evento_id and e.slug = p_evento_slug
    left join participante_perfil pp on pp.participante_id = pa.id
    where pa.status = 'aprovado'
    order by (pp.participante_id is null), g.empresa, g.nome
    limit p_limite offset p_offset;
end;
$$;

revoke execute on function admin_rel_pesquisa(text, integer, integer) from public, anon;
grant execute on function admin_rel_pesquisa(text, integer, integer) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- autoconfere: a coluna nova (perfil_ingresso) existe no retorno da
-- funcao, e checa a definicao de verdade (pg_get_function_result), nao
-- um teste isolado
-- ---------------------------------------------------------------------
do $$
declare v_retorno text;
begin
  select pg_get_function_result('gestao.admin_rel_pesquisa(text,integer,integer)'::regprocedure)
    into v_retorno;

  if v_retorno !~ '^TABLE\(perfil_ingresso text' then
    raise exception 'admin_rel_pesquisa nao comeca com perfil_ingresso: %', v_retorno;
  end if;

  raise notice 'admin_rel_pesquisa: retorno confirmado com perfil_ingresso na frente.';
end $$;
