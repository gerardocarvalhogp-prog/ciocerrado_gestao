-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Duas ferramentas de manutencao da base: fundir duplicados e criar/
-- vincular empresas.
--
-- POR QUE FUNCAO, E NAO UM UPDATE DE UMA VEZ
--
-- Ja fundi duplicados uma vez (migration de 25/08), e eles voltaram —
-- e o que acontece toda vez que entra planilha nova. Migration resolve
-- o dia; funcao resolve o mes. As duas ficam chamaveis pela tela.
--
-- 1. admin_fundir_duplicados
--
-- Criterio deliberadamente estreito: mesmo nome E mesma empresa. So
-- isso e duplicata com seguranca. Nome igual em empresa diferente e
-- homonimo ou troca de emprego — juntar seria fundir duas pessoas.
-- Na base de hoje isso e a diferenca entre 2 pares (seguros) e 21
-- (dos quais a maioria e gente diferente).
--
-- Sobrevive quem tem mais campo preenchido; o outro so e apagado
-- depois de o sobrevivente herdar o que lhe faltava e de todas as
-- referencias serem redirecionadas.
--
-- 2. admin_vincular_empresas
--
-- gestores.empresa e texto livre. A tabela empresas existe desde 25/08
-- e esta vazia porque o vinculo era manual, um a um — inviavel para
-- 1.469 gestores.
--
-- Aqui o casamento e por nome normalizado (sem acento, sem
-- maiuscula, sem espaco duplo). Isso junta "Coca-Cola" com "COCA
-- COLA", que e o que se quer. NAO tenta casamento aproximado: "Grupo
-- Petropolis" e "Petropolis" continuam separadas, porque adivinhar
-- ali junta empresas que sao mesmo diferentes, e o estrago so
-- aparece depois.
-- =====================================================================

set search_path = gestao, public;

CREATE OR REPLACE FUNCTION "gestao"."admin_fundir_duplicados"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare
  r record; v_sobrevive uuid; v_perde uuid; v_n int := 0;
begin
  perform _exige_admin();

  for r in
    select a.id as id1, b.id as id2,
      (case when a.email is not null then 1 else 0 end
       + case when a.telefone is not null then 1 else 0 end
       + case when a.cargo is not null then 1 else 0 end
       + case when a.cnpj is not null then 1 else 0 end
       + case when a.cidade is not null then 1 else 0 end
       + case when a.perfil is not null then 1 else 0 end
       + case when a.linkedin is not null then 1 else 0 end) as s1,
      (case when b.email is not null then 1 else 0 end
       + case when b.telefone is not null then 1 else 0 end
       + case when b.cargo is not null then 1 else 0 end
       + case when b.cnpj is not null then 1 else 0 end
       + case when b.cidade is not null then 1 else 0 end
       + case when b.perfil is not null then 1 else 0 end
       + case when b.linkedin is not null then 1 else 0 end) as s2
    from gestores a
    join gestores b
      on lower(unaccent('unaccent', a.nome)) = lower(unaccent('unaccent', b.nome))
      and lower(unaccent('unaccent', coalesce(a.empresa,'')))
        = lower(unaccent('unaccent', coalesce(b.empresa,'')))
      and coalesce(trim(a.empresa),'') <> ''   -- sem empresa nao da para afirmar
      and a.id < b.id
  loop
    if r.s1 >= r.s2 then v_sobrevive := r.id1; v_perde := r.id2;
    else                 v_sobrevive := r.id2; v_perde := r.id1;
    end if;

    -- o sobrevivente herda o que nao tinha
    update gestores s set
      email        = coalesce(s.email, p.email),
      telefone     = coalesce(s.telefone, p.telefone),
      cargo        = coalesce(s.cargo, p.cargo),
      cnpj         = coalesce(s.cnpj, p.cnpj),
      cidade       = coalesce(s.cidade, p.cidade),
      estado       = coalesce(s.estado, p.estado),
      segmento     = coalesce(s.segmento, p.segmento),
      perfil       = coalesce(s.perfil, p.perfil),
      linkedin     = coalesce(s.linkedin, p.linkedin),
      faturamento  = coalesce(s.faturamento, p.faturamento),
      funcionarios = coalesce(s.funcionarios, p.funcionarios),
      posicao_gestor = coalesce(s.posicao_gestor, p.posicao_gestor),
      empresa_id   = coalesce(s.empresa_id, p.empresa_id)
    from gestores p
    where s.id = v_sobrevive and p.id = v_perde;

    -- toda referencia aponta para o sobrevivente antes do delete
    update gestores_historico set gestor_id = v_sobrevive where gestor_id = v_perde;
    update indicacoes         set gestor_id = v_sobrevive where gestor_id = v_perde;
    update prospeccoes        set gestor_id = v_sobrevive where gestor_id = v_perde;
    update sugestoes_ia       set gestor_id = v_sobrevive where gestor_id = v_perde;

    -- jantar_convidados e participantes tem unique com o gestor: mover
    -- cegamente violaria a chave se os dois ja estiverem no mesmo
    -- jantar/evento. Move o que nao colide e descarta o resto — a
    -- linha do sobrevivente ja cobre aquele jantar/evento.
    update jantar_convidados jc set gestor_id = v_sobrevive
     where jc.gestor_id = v_perde
       and not exists (select 1 from jantar_convidados x
                        where x.jantar_id = jc.jantar_id and x.gestor_id = v_sobrevive);
    delete from jantar_convidados where gestor_id = v_perde;

    update participantes pa set gestor_id = v_sobrevive
     where pa.gestor_id = v_perde
       and not exists (select 1 from participantes y
                        where y.evento_id = pa.evento_id and y.gestor_id = v_sobrevive);
    delete from participantes where gestor_id = v_perde;

    delete from gestores where id = v_perde;
    v_n := v_n + 1;
  end loop;

  return jsonb_build_object('ok', true, 'fundidos', v_n);
end;
$$;

REVOKE ALL ON FUNCTION "gestao"."admin_fundir_duplicados"() FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_fundir_duplicados"() TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_fundir_duplicados"() TO "service_role";


CREATE OR REPLACE FUNCTION "gestao"."admin_vincular_empresas"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_criadas int := 0; v_vinculados int := 0;
begin
  perform _exige_admin();

  -- 1. cria as que faltam, uma por nome normalizado. O nome gravado e
  --    a grafia mais frequente na base, nao a primeira encontrada:
  --    "COCA COLA" digitado 40 vezes ganha de "coca cola" digitado 1.
  with nomes as (
    select lower(unaccent('unaccent', regexp_replace(trim(empresa), '\s+', ' ', 'g'))) as chave,
           trim(empresa) as nome, count(*) as n
    from gestores
    where coalesce(trim(empresa),'') <> ''
    group by 1, 2
  ),
  melhor as (
    select distinct on (chave) chave, nome
    from nomes order by chave, n desc, nome
  )
  insert into empresas (nome)
  select m.nome from melhor m
  where not exists (
    select 1 from empresas e
    where lower(unaccent('unaccent', regexp_replace(trim(e.nome), '\s+', ' ', 'g'))) = m.chave);
  get diagnostics v_criadas = row_count;

  -- 2. liga quem ainda nao tem vinculo
  update gestores g set empresa_id = e.id
  from empresas e
  where g.empresa_id is null
    and coalesce(trim(g.empresa),'') <> ''
    and lower(unaccent('unaccent', regexp_replace(trim(e.nome), '\s+', ' ', 'g')))
      = lower(unaccent('unaccent', regexp_replace(trim(g.empresa), '\s+', ' ', 'g')));
  get diagnostics v_vinculados = row_count;

  return jsonb_build_object('ok', true,
    'empresas_criadas', v_criadas, 'gestores_vinculados', v_vinculados);
end;
$$;

REVOKE ALL ON FUNCTION "gestao"."admin_vincular_empresas"() FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_vincular_empresas"() TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_vincular_empresas"() TO "service_role";
