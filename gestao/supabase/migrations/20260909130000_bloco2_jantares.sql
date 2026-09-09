-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Bloco 2 — ajustes diretos em Jantares.
--
-- 2.1 Lista de convidados ordena por nome (era: status, depois empresa).
-- 2.2 jantar_convidados_listar ja trazia cargo/email/telefone/segmento/
--     cidade/estado/natureza/justificativa — so a tela nunca mostrava.
--     Acrescenta linkedin e observacao pra completar o "dados
--     completos" que abre ao clicar no nome (feito em admin.html).
-- 2.3 Novo status 'em_analise', antes de 'convidado' vira 'confirmado'
--     — entra no CHECK da tabela e na validacao de jantar_marcar_convidado.
-- 2.4 tem_cracha: participante aprovado do evento aberto ja tem crachá
--     do evento grande — sai da emissão de etiquetas em massa, mas
--     continua disponível pra imprimir avulsa (front-end decide).
--
-- De quebra: 'em_analise' entra no mesmo grupo de 'convidado' nas
-- estatisticas ja existentes (jantar_estatisticas_confirmacao/
-- _panorama), senao esses convidados ficariam invisiveis nos
-- indicadores — mesmo escopo de mudanca, nao adianta deixar pela
-- metade. O relatorio dedicado (com "em analise" como coluna propria)
-- fica pro Bloco 5.6.
-- =====================================================================

set search_path = gestao, public;

alter table jantar_convidados drop constraint if exists jantar_convidados_status_check;
alter table jantar_convidados add constraint jantar_convidados_status_check
  check (status = any (array['sugerido','convidado','em_analise','confirmado','recusado','compareceu']));

create or replace function jantar_marcar_convidado(p_id uuid, p_status text, p_observacao text DEFAULT NULL::text)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_jantar uuid; v_cap int; v_ocupados int;
begin
  perform _exige_staff();

  if p_status not in ('sugerido','convidado','em_analise','confirmado','recusado','compareceu') then
    raise exception 'Status invalido: %', p_status using errcode='22023';
  end if;

  select jc.jantar_id into v_jantar from jantar_convidados jc where jc.id = p_id;
  if v_jantar is null then
    raise exception 'Convidado nao encontrado' using errcode='P0002';
  end if;

  if p_status in ('confirmado','compareceu') then
    select capacidade into v_cap from jantares where id = v_jantar;
    select count(*) into v_ocupados from jantar_convidados
     where jantar_id = v_jantar and status in ('confirmado','compareceu')
       and id <> p_id;
    if v_ocupados >= v_cap then
      raise exception 'O jantar já está com todas as % vaga(s) ocupadas', v_cap
        using errcode='22023';
    end if;
  end if;

  update jantar_convidados set
    status = p_status,
    observacao = coalesce(p_observacao, observacao)
  where id = p_id;

  return jsonb_build_object('ok', true);
end;
$$;

drop function if exists jantar_convidados_listar(uuid);

create function jantar_convidados_listar(p_jantar_id uuid) returns table(
  id uuid, gestor_id uuid, nome text, empresa text,
  cargo text, email text, telefone text, origem text,
  rotulo text, score numeric, natureza text,
  justificativa text, status text, observacao text,
  segmento text, cidade text, estado text, linkedin text,
  tem_cracha boolean
)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();
  return query
    select jc.id, jc.gestor_id, g.nome, coalesce(jc.empresa, g.empresa),
           g.cargo, g.email, g.telefone, jc.origem, jc.rotulo,
           jc.score, jc.natureza, jc.justificativa, jc.status, jc.observacao,
           coalesce(g.segmento, e.segmento),
           coalesce(g.cidade, e.cidade),
           coalesce(g.estado, e.estado),
           g.linkedin,
           exists (
             select 1 from participantes pa
             join eventos ev on ev.id = pa.evento_id
             where pa.gestor_id = jc.gestor_id
               and ev.status = 'aberto'
               and pa.status not in ('recusado','cancelado')
           )
    from jantar_convidados jc
    join gestores g on g.id = jc.gestor_id
    left join empresas e on e.id = g.empresa_id
    where jc.jantar_id = p_jantar_id
    order by g.nome;
end;
$$;

revoke execute on function jantar_convidados_listar(uuid) from public, anon;
grant execute on function jantar_convidados_listar(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 'em_analise' some das estatisticas ja existentes se nao entrar no
-- mesmo grupo de 'convidado' — mesma assinatura, so o corpo muda.
-- ---------------------------------------------------------------------
create or replace function jantar_estatisticas_confirmacao(p_limite integer DEFAULT 200)
returns table(
  gestor_id uuid, nome text, empresa text, cargo text,
  n_convites integer, n_confirmados integer, n_compareceu integer,
  n_sem_comparecimento integer, taxa numeric, ultima_vez date
)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();
  return query
    select
      g.id, g.nome, g.empresa, g.cargo,
      count(*) filter (where jc.status in ('convidado','em_analise','confirmado','compareceu','recusado'))::int,
      count(*) filter (where jc.status in ('confirmado','compareceu'))::int,
      count(*) filter (where jc.status = 'compareceu')::int,
      count(*) filter (where jc.status = 'confirmado' and j.data < current_date)::int,
      case when count(*) filter (where jc.status in ('convidado','em_analise','confirmado','compareceu','recusado')) > 0
        then round(100.0 * count(*) filter (where jc.status in ('confirmado','compareceu'))
                  / count(*) filter (where jc.status in ('convidado','em_analise','confirmado','compareceu','recusado')))
        else 0 end,
      max(j.data)
    from jantar_convidados jc
    join jantares j on j.id = jc.jantar_id
    join gestores g on g.id = jc.gestor_id
    where g.perfil is distinct from 'CIO CERRADO'
    group by g.id, g.nome, g.empresa, g.cargo
    having count(*) filter (where jc.status in ('convidado','em_analise','confirmado','compareceu','recusado')) > 0
    order by 5 desc, g.nome
    limit p_limite;
end;
$$;

create or replace function jantar_estatisticas_panorama()
returns jsonb language plpgsql stable security definer
set search_path = gestao, public as $$
declare v jsonb;
begin
  perform _exige_staff();
  with base as (
    select g.id,
      count(*) filter (where jc.status in ('convidado','em_analise','confirmado','compareceu','recusado')) as n
    from jantar_convidados jc
    join gestores g on g.id = jc.gestor_id
    where g.perfil is distinct from 'CIO CERRADO'
    group by g.id
    having count(*) filter (where jc.status in ('convidado','em_analise','confirmado','compareceu','recusado')) > 0
  )
  select jsonb_build_object(
    'total_jantares', (select count(*) from jantares),
    'total_pessoas', (select count(*) from base),
    'uma_vez', (select count(*) from base where n = 1),
    'tres_mais', (select count(*) from base where n >= 3),
    'dez_mais', (select count(*) from base where n >= 10),
    'total_convites', (select coalesce(sum(n),0) from base),
    'total_confirmados', (
      select count(*) from jantar_convidados jc join gestores g on g.id = jc.gestor_id
       where jc.status in ('confirmado','compareceu') and g.perfil is distinct from 'CIO CERRADO'),
    'total_sem_comparecimento', (
      select count(*) from jantar_convidados jc join jantares j on j.id = jc.jantar_id
       join gestores g on g.id = jc.gestor_id
       where jc.status = 'confirmado' and j.data < current_date
         and g.perfil is distinct from 'CIO CERRADO')
  ) into v;
  return v;
end;
$$;
