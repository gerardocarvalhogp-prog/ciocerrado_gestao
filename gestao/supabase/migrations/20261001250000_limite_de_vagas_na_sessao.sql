-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- admin_adicionar_convidado_sessao (mesa redonda / reuniao exclusiva /
-- jantar) nunca conferiu vaga — so fazia insert, sem olhar
-- sessoes.vagas. Dava pra colocar CIO a mais numa mesa cheia pela tela
-- de staff, mesmo com admin_salvar_sessao ja impedindo DIMINUIR vagas
-- abaixo de quem esta confirmado (prova que o limite sempre foi pra
-- valer, so faltava aplicar na hora de ADICIONAR). Pedido do
-- organizador em 01/10/2026. Buraco existe desde o baseline — nao e
-- regressao de migration nenhuma.
--
-- DE BRINDE, ACHADO CONFERINDO A TABELA ANTES DE MEXER: sessao_convidados
-- nunca teve UNIQUE em (sessao_id, participante_id) — so' PK em id. O
-- "on conflict do nothing" do insert nunca tinha o que conflitar com,
-- entao clicar "Adicionar" duas vezes na mesma pessoa criava DUAS
-- linhas. Sem contar isso, a conta de vaga ocupada ficaria errada
-- (inflada por duplicata, ou um "removido" velho escondendo uma vaga
-- livre de verdade). Resolvido junto, no mesmo commit, porque o
-- check de vaga so' e' confiavel com a contagem certa:
--
--   1. desduplica o que ja existe (mantém a linha 'confirmado' se
--      houver, senão a mais recente)
--   2. cria o UNIQUE que faltava
--   3. redefine a funcao: trava a linha da sessao (FOR UPDATE, mesmo
--      padrao de concorrencia do resto do schema), conta so' quem
--      esta 'confirmado' hoje, recusa se nao houver vaga, e o insert
--      vira upsert de verdade (reconfirmar quem ja esta, ou trazer de
--      volta quem tinha sido removido, em vez de so' tentar inserir
--      de novo e nunca atualizar).
-- =====================================================================

set search_path = gestao, public;

-- ---------------------------------------------------------------------
-- 1. DESDUPLICA O QUE JA EXISTE
-- ---------------------------------------------------------------------
with ranqueado as (
  select id,
         row_number() over (
           partition by sessao_id, participante_id
           order by (status = 'confirmado') desc, created_at desc, id desc
         ) as posicao
  from sessao_convidados
)
delete from sessao_convidados where id in (select id from ranqueado where posicao > 1);

-- ---------------------------------------------------------------------
-- 2. UNIQUE QUE SEMPRE FALTOU
-- ---------------------------------------------------------------------
create unique index if not exists sessao_convidados_sessao_participante_uk
  on sessao_convidados (sessao_id, participante_id);

-- ---------------------------------------------------------------------
-- 3. ADMIN_ADICIONAR_CONVIDADO_SESSAO CONFERE VAGA
-- ---------------------------------------------------------------------
create or replace function admin_adicionar_convidado_sessao(p_sessao_id uuid, p_participante_id uuid, p_aderencia numeric DEFAULT NULL::numeric)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_vagas int;
  v_ocupadas int;
begin
  perform _exige_staff_da_sessao(p_sessao_id);

  select vagas into v_vagas from sessoes where id = p_sessao_id for update;
  if not found then
    raise exception 'Sessao nao encontrada' using errcode = 'P0002';
  end if;

  -- nao conta a propria pessoa: reconfirmar quem ja esta (ou trazer de
  -- volta quem foi removido) nunca deveria esbarrar na propria vaga
  select count(*) into v_ocupadas from sessao_convidados
   where sessao_id = p_sessao_id and status = 'confirmado'
     and participante_id <> p_participante_id;

  if v_ocupadas >= coalesce(v_vagas, 0) then
    raise exception 'Mesa sem vaga: % de % confirmado(s)', v_ocupadas, coalesce(v_vagas,0)
      using errcode = '55000';
  end if;

  insert into sessao_convidados (sessao_id, participante_id, origem, aderencia)
  values (p_sessao_id, p_participante_id, 'admin', p_aderencia)
  on conflict (sessao_id, participante_id) do update set
    status = 'confirmado',
    origem = 'admin',
    aderencia = coalesce(excluded.aderencia, sessao_convidados.aderencia);

  return jsonb_build_object('ok', true);
end;
$$;

revoke execute on function admin_adicionar_convidado_sessao(uuid, uuid, numeric) from public, anon;
grant execute on function admin_adicionar_convidado_sessao(uuid, uuid, numeric) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- autoconfere: nao sobrou duplicata, e o unique esta de pe
-- ---------------------------------------------------------------------
do $$
declare v_duplicatas int;
begin
  select count(*) into v_duplicatas
  from (
    select sessao_id, participante_id from sessao_convidados
    group by 1, 2 having count(*) > 1
  ) x;
  if v_duplicatas > 0 then
    raise exception '% par(es) sessao+participante ainda duplicado(s) apos a desduplicacao', v_duplicatas;
  end if;

  if not exists (
    select 1 from pg_indexes
    where schemaname = 'gestao' and indexname = 'sessao_convidados_sessao_participante_uk'
  ) then
    raise exception 'sessao_convidados_sessao_participante_uk nao foi criado';
  end if;

  raise notice 'sessao_convidados: sem duplicata, unique criado, limite de vaga em vigor.';
end $$;
