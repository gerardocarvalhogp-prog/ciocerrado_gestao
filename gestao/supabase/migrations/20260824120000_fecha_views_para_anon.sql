-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Fecha o vazamento das views e tira o anon das tabelas.
--
-- O QUE FOI MEDIDO, EM 24/08/2026
--
-- Com a chave anon — que esta publicada dentro dos cinco .html — e sem
-- login nenhum, isto respondia com dados:
--
--   GET /rest/v1/v_painel_participantes   nome, empresa, status de cada
--                                         participante
--   GET /rest/v1/v_etiquetas              nome, empresa, apartamento
--   GET /rest/v1/v_esperados              lista de quem e esperado
--   GET /rest/v1/v_ordem_escolha          a fila de escolha das mesas
--   GET /rest/v1/v_checkins_resumo        check-ins por empresa
--   GET /rest/v1/v_disponibilidade_quartos
--
-- As TABELAS estavam protegidas: as 29 tem RLS ligada, as 37 politicas
-- sao todas escopadas e nenhuma vale para anon. As mesmas consultas
-- contra `gestores`, `participantes`, `faturas` e companhia voltaram [].
--
-- POR QUE SO AS VIEWS VAZAVAM
--
-- View no Postgres roda com o dono, nao com quem consulta. As seis
-- pertencem ao postgres, entao a RLS das tabelas de baixo simplesmente
-- nao e aplicada — e o `GRANT ALL ON TABLE ... TO anon` que o Supabase
-- coloca por padrao abre a porta. O linter do proprio Supabase marca
-- isso como ERROR (`security_definer_view`), seis vezes.
--
-- Hoje o dano seria pequeno: o banco tem 8 participantes de teste. Com
-- os ~130 CIOs e 61 patrocinadores de 2027 la dentro, seria a lista de
-- convidados inteira, aberta, para quem lesse o codigo-fonte da pagina.
--
-- A CORRECAO, EM DUAS CAMADAS
--
-- 1. `security_invoker = true` nas seis: a view passa a rodar com quem
--    consulta e a RLS das tabelas volta a valer. Funcao SECURITY
--    DEFINER que le essas views continua enxergando tudo, porque roda
--    como postgres, que e dono das tabelas e nao esta sob FORCE RLS —
--    conferido: nenhuma das 29 tem relforcerowsecurity.
--
-- 2. Tirar `anon` das tabelas e views deste schema, e do default
--    privilege que faz toda tabela nova ja nascer aberta. O anon nao
--    precisa de tabela nenhuma: as telas so falam por RPC (nenhum
--    `.from(` nos cinco .html) e o unico caminho anonimo e
--    `part_autocadastro`, que continua liberado.
--
-- `authenticated` continua com acesso as tabelas, sob RLS. Fechar
-- tambem seria defesa em profundidade, mas mexe no que ja funciona e
-- pede um teste de tela antes — fica anotado no README.
-- =====================================================================

set search_path = gestao, public;

-- ---------------------------------------------------------------------
-- 1. AS VIEWS PASSAM A RESPEITAR A RLS DE QUEM CONSULTA
-- ---------------------------------------------------------------------
alter view v_painel_participantes    set (security_invoker = true);
alter view v_etiquetas               set (security_invoker = true);
alter view v_esperados               set (security_invoker = true);
alter view v_ordem_escolha           set (security_invoker = true);
alter view v_checkins_resumo         set (security_invoker = true);
alter view v_disponibilidade_quartos set (security_invoker = true);

-- ---------------------------------------------------------------------
-- 2. O ANON SAI DAS TABELAS
-- ---------------------------------------------------------------------
-- `for role postgres` explicito: sem isso o alvo e o papel da conexao,
-- e quem concedeu foi o postgres (esta assim no dump). Se o CLI
-- conectasse como outro papel, isto criaria uma entrada nova em vez de
-- desfazer a que existe — e nao mudaria nada.
alter default privileges for role postgres in schema gestao
  revoke all on tables from anon;
revoke all on all tables in schema gestao from anon;

-- O anon ainda precisa enxergar o schema para chamar part_autocadastro.
grant usage on schema gestao to anon;

-- ---------------------------------------------------------------------
-- 3. SEARCH_PATH FIXO NOS AUXILIARES
--
-- O linter marca dez funcoes com search_path mutavel. Nenhuma e
-- SECURITY DEFINER — conferido — entao nao ha escalada de privilegio
-- aqui; e higiene: funcao sem search_path resolve nome pelo caminho de
-- quem chama, e um dia isso surpreende.
--
-- `norm_doc` e `norm_cpf` ficam de fora de proposito: as duas alimentam
-- colunas GENERATED em admins, gestores e usuarios_patrocinador, e
-- mexer nelas mexe na definicao dessas colunas. Nao vale o risco por um
-- aviso de higiene.
-- ---------------------------------------------------------------------
alter function _porte_faturamento(text)                set search_path = gestao, public;
alter function _fim_da_janela(timestamptz, int, date, timestamptz, boolean)
                                                       set search_path = gestao, public;
alter function _item_do_ocupante(text)                 set search_path = gestao, public;
alter function _rotulo_faixa(int, int)                 set search_path = gestao, public;
alter function _intencao(text)                         set search_path = gestao, public;
alter function _rank_cargo(text)                       set search_path = gestao, public;
alter function _rank_pos(text)                         set search_path = gestao, public;
alter function touch_updated_at()                      set search_path = gestao, public;

-- ---------------------------------------------------------------------
-- 4. FALHA EM VEZ DE PASSAR CALADO
-- ---------------------------------------------------------------------
do $$
declare v_abertas text; v_tabelas text;
begin
  select string_agg(c.relname, ', ' order by c.relname) into v_abertas
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'gestao' and c.relkind = 'v'
    and coalesce((select option_value from pg_options_to_table(c.reloptions)
                  where option_name = 'security_invoker'), 'false') <> 'true';
  if v_abertas is not null then
    raise exception 'view sem security_invoker: %', v_abertas;
  end if;

  select string_agg(c.relname, ', ' order by c.relname) into v_tabelas
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'gestao' and c.relkind in ('r','v')
    and has_table_privilege('anon', c.oid, 'SELECT');
  if v_tabelas is not null then
    raise exception 'anon ainda le: %', v_tabelas;
  end if;

  raise notice 'OK: views com security_invoker, anon sem acesso a tabela';
end $$;
