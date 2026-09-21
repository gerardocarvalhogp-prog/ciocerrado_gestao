-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Abandona a criacao/convite de evento por robo de navegador
-- (rpa_sympla_jantares.py, Playwright no painel de produtor).
--
-- Motivo: instavel na pratica — o painel do Sympla muda sem aviso e
-- quebra seletor, e login com OTP em duas etapas nao da pra automatizar
-- de ponta a ponta. Decisao do organizador em 21/09/2026: criar o
-- evento e mandar convite direto no painel do Sympla, colar o link em
-- jantares.html (ja e' como o campo sempre funcionou — nunca dependeu
-- do robo pra ser preenchido), e acompanhar quem confirmou/recusou
-- convite pela API publica de leitura (integracao.py --jantares, ja em
-- producao, roda a cada 2h). O robo em si ja foi removido do repositorio.
--
-- Este bloco so' desfaz a metade do banco que existia unicamente pra
-- servir o robo:
--   1. jantar_listar_para_sympla() — a "fila" que dizia pro robo o que
--      criar. Sem robo, sem fila.
--   2. jantar_marcar_sympla() — como o robo confirmava de volta que
--      tinha criado o evento ou mandado convite. Ninguem mais chama.
--   3. sympla_status: o terceiro estado, 'convites_enviados', so' era
--      alcancavel por jantar_marcar_sympla() depois que o robo simulava
--      um convite — sem ele, e' um estado morto que nunca mais vai ser
--      setado. Colapsa pra 2 estados (pendente/criado); linhas que ja
--      estavam em 'convites_enviados' viram 'criado', que e' a
--      informacao que ainda e' verdadeira (o evento existe, tem link).
-- =====================================================================

set search_path = gestao, public;

drop function if exists jantar_listar_para_sympla();
drop function if exists jantar_marcar_sympla(uuid, text, text);

update jantares set sympla_status = 'criado' where sympla_status = 'convites_enviados';

-- acha o nome da constraint na marra em vez de supor o padrao de
-- nomeacao automatica do Postgres (tabela_coluna_check) — mais barato
-- que descobrir em producao que o nome inferido nao bateu
do $$
declare v_nome text;
begin
  select conname into v_nome from pg_constraint
   where conrelid = 'jantares'::regclass and contype = 'c'
     and pg_get_constraintdef(oid) ilike '%sympla_status%';
  if v_nome is not null then
    execute format('alter table jantares drop constraint %I', v_nome);
  end if;
end $$;

alter table jantares add constraint jantares_sympla_status_check
  check (sympla_status in ('pendente','criado'));

comment on column jantares.sympla_status is
  'pendente = sem link do Sympla ainda. criado = link preenchido — evento e convites sao geridos na mao, direto no painel do Sympla; confirmacao/recusa de presenca vem da API publica de leitura (integracao.py --jantares).';

-- ---------------------------------------------------------------------
-- Self-check: as duas funcoes do robo sumiram, o estado morto nao
-- sobrou linha nenhuma, e a constraint aceita so' os 2 estados atuais.
-- ---------------------------------------------------------------------
do $$
declare v_orfaos int; v_funcoes int;
begin
  select count(*) into v_orfaos from jantares where sympla_status = 'convites_enviados';
  if v_orfaos > 0 then
    raise exception 'sobrou % jantar(es) em convites_enviados apos a migracao', v_orfaos;
  end if;

  select count(*) into v_funcoes from pg_proc
   where pronamespace = 'gestao'::regnamespace
     and proname in ('jantar_listar_para_sympla','jantar_marcar_sympla');
  if v_funcoes > 0 then
    raise exception 'ainda existe(m) % funcao(oes) do robo do Sympla que deveriam ter sido removidas', v_funcoes;
  end if;
end $$;
