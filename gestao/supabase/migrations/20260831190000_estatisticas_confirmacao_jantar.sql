-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Leva o relatorio de convites (feito em cima da planilha antiga) para
-- dentro do sistema — como estatistica ao vivo em cima de
-- jantar_convidados, nao mais uma extracao avulsa de Excel.
--
-- O QUE A TELA JA TINHA, E O QUE FALTAVA
--
-- jantar_estatisticas_gestores existia, mas so contava quem tinha
-- status 'confirmado' ou 'compareceu' — quem e convidado sempre e
-- nunca confirma simplesmente NAO APARECIA na lista, porque a funcao
-- nunca olhava pra essas linhas. O nome do card ("Quem mais foi
-- convidado") tambem estava errado: o que ela media era "quem mais
-- confirmou", nao "quem mais foi chamado".
--
-- Isso e exatamente o padrao que apareceu analisando a planilha antiga
-- (aba Convite Jantares, 44 jantares, 893 pessoas): 77 pessoas
-- convidadas 3+ vezes com ZERO confirmacoes. Sem contar quem nao
-- confirma, o sistema nunca teria como mostrar isso.
--
-- O QUE A PLANILHA NAO CONSEGUIA MEDIR, E O SISTEMA NOVO CONSEGUE
--
-- A planilha tinha um status "50 - NAO COMPARECEU" que parou de ser
-- usado — nos dados atuais, ninguem tem esse status, so "confirmado"
-- sem atualizacao depois. jantar_convidados.status ja distingue
-- 'confirmado' de 'compareceu' como dois valores separados (o segundo
-- so e marcado no check-in da porta) — entao da pra calcular de
-- verdade quem confirmou presenca num jantar QUE JA ACONTECEU
-- (j.data < hoje) e nunca virou 'compareceu'. Essa e a pergunta que a
-- planilha nao respondia.
--
-- jantar_estatisticas_gestores (a funcao antiga) fica no lugar, sem
-- uso pelo front — nao ha necessidade de apagar, e romper ela a toa
-- arrisca quem eventualmente a chame por fora da tela.
--
-- EQUIPE DO CIO CERRADO FICA DE FORA
--
-- perfil = 'CIO CERRADO' e a propria equipe organizadora — ela vai a
-- todo jantar que promove, entao contar "vezes convidada" pra ela so
-- polui o ranking. IS DISTINCT FROM cobre certo o caso de perfil nulo.
-- =====================================================================

set search_path = gestao, public;

CREATE OR REPLACE FUNCTION "gestao"."jantar_estatisticas_confirmacao"(
  "p_limite" integer DEFAULT 200
) RETURNS TABLE(
  "gestor_id" "uuid", "nome" "text", "empresa" "text", "cargo" "text",
  "n_convites" integer, "n_confirmados" integer, "n_compareceu" integer,
  "n_sem_comparecimento" integer, "taxa" numeric, "ultima_vez" "date"
)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select
      g.id, g.nome, g.empresa, g.cargo,
      count(*) filter (where jc.status in ('convidado','confirmado','compareceu','recusado'))::int,
      count(*) filter (where jc.status in ('confirmado','compareceu'))::int,
      count(*) filter (where jc.status = 'compareceu')::int,
      -- confirmou, o jantar ja aconteceu, e o check-in nunca marcou
      -- 'compareceu' — a pergunta que a planilha antiga nao respondia
      count(*) filter (where jc.status = 'confirmado' and j.data < current_date)::int,
      case when count(*) filter (where jc.status in ('convidado','confirmado','compareceu','recusado')) > 0
        then round(100.0 * count(*) filter (where jc.status in ('confirmado','compareceu'))
                  / count(*) filter (where jc.status in ('convidado','confirmado','compareceu','recusado')))
        else 0 end,
      max(j.data)
    from jantar_convidados jc
    join jantares j on j.id = jc.jantar_id
    join gestores g on g.id = jc.gestor_id
    where g.perfil is distinct from 'CIO CERRADO'
    group by g.id, g.nome, g.empresa, g.cargo
    having count(*) filter (where jc.status in ('convidado','confirmado','compareceu','recusado')) > 0
    order by 5 desc, g.nome
    limit p_limite;
end;
$$;

REVOKE ALL ON FUNCTION "gestao"."jantar_estatisticas_confirmacao"(integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."jantar_estatisticas_confirmacao"(integer) TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."jantar_estatisticas_confirmacao"(integer) TO "service_role";


-- Numeros de panorama, sem paginacao — a tira do topo da tela.
CREATE OR REPLACE FUNCTION "gestao"."jantar_estatisticas_panorama"() RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v jsonb;
begin
  perform _exige_staff();
  with base as (
    select g.id,
      count(*) filter (where jc.status in ('convidado','confirmado','compareceu','recusado')) as n
    from jantar_convidados jc
    join gestores g on g.id = jc.gestor_id
    where g.perfil is distinct from 'CIO CERRADO'
    group by g.id
    having count(*) filter (where jc.status in ('convidado','confirmado','compareceu','recusado')) > 0
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

REVOKE ALL ON FUNCTION "gestao"."jantar_estatisticas_panorama"() FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."jantar_estatisticas_panorama"() TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."jantar_estatisticas_panorama"() TO "service_role";
