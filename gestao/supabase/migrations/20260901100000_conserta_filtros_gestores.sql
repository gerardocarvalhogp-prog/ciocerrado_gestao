-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- admin_filtros_gestores nunca funcionou — coluna "v" ambigua.
--
-- A funcao declara uma variavel PL/pgSQL chamada `v` no topo, e cada um
-- dos cinco blocos (perfis, segmentos, estados, cidades, posicoes) monta
-- uma subquery cuja coluna TAMBEM se chama `v` (`select perfil v, ...`)
-- e depois ordena por ela (`order by n desc, v`). Dentro do ORDER BY da
-- subquery, "v" podia ser a variavel da funcao ou a coluna — Postgres
-- recusa a ambiguidade e a chamada inteira falhava com
-- "column reference \"v\" is ambiguous".
--
-- Efeito na tela: os selects de Segmento, Cidade, UF, Perfil e Posicao
-- em Cadastro nunca populavam — o catch(e){} silencioso em
-- carregarFiltros() (admin.html) engolia o erro, entao parecia so
-- "vazio", nao quebrado. E o motivo do achado do usuario ("filtros nao
-- trazem segmento, cidade e UF").
--
-- Existe desde a migration que criou a funcao (20260828130000/
-- 20260828190000) — nao e regressao de nada feito esta semana.
--
-- CONSERTO: renomeia so a variavel da funcao (v -> v_out). As colunas
-- das subqueries continuam se chamando "v" de proposito (e o nome que
-- `encher()` no front-end espera em cada objeto: {v, n}).
-- =====================================================================

set search_path = gestao, public;

create or replace function admin_filtros_gestores()
returns jsonb language plpgsql stable security definer
set search_path = gestao, public as $$
declare v_out jsonb;
begin
  perform _exige_admin();
  select jsonb_build_object(
    'perfis',    (select coalesce(jsonb_agg(jsonb_build_object('v', v, 'n', n)
                                            order by n desc, v),'[]'::jsonb)
                    from (select perfil v, count(*) n from gestores
                           where coalesce(trim(perfil),'') <> '' group by 1) a),
    'segmentos', (select coalesce(jsonb_agg(jsonb_build_object('v', v, 'n', n)
                                            order by codigo),'[]'::jsonb)
                    from (select s.codigo, s.nome v,
                                 (select count(*) from gestores g
                                   where g.segmento = s.nome) n
                            from segmentos s where s.ativo) b),
    'estados',   (select coalesce(jsonb_agg(jsonb_build_object('v', v, 'n', n)
                                            order by n desc, v),'[]'::jsonb)
                    from (select upper(estado) v, count(*) n from gestores
                           where coalesce(trim(estado),'') <> '' group by 1) c),
    'cidades',   (select coalesce(jsonb_agg(jsonb_build_object('v', v, 'n', n)
                                            order by n desc, v),'[]'::jsonb)
                    from (select cidade v, count(*) n from gestores
                           where coalesce(trim(cidade),'') <> '' group by 1) d),
    'posicoes',  (select coalesce(jsonb_agg(jsonb_build_object('v', v, 'n', n)
                                            order by v),'[]'::jsonb)
                    from (select posicao_gestor v, count(*) n from gestores
                           where coalesce(trim(posicao_gestor),'') <> '' group by 1) e)
  ) into v_out;
  return v_out;
end;
$$;
