-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Funde o gestor de teste "GERARDO CARVALHO DA JUNIOR" (criado pela
-- sincronizacao do Sympla, e-mail pessoal) no gestor de verdade
-- "GERARDO CARVALHO" (ja cadastrado, e-mail corporativo
-- gerardo.carvalho@atacadaodiaadia.com.br) — pedido do organizador em
-- 01/10/2026, achado ao tentar corrigir o e-mail na mao e esbarrar em
-- "duplicate key value violates unique constraint gestores_email_uk".
--
-- admin_fundir_duplicados() nao pega este par de proposito: ela exige
-- MESMO nome E MESMA empresa (migration 20260828180000), e aqui nome
-- ("GERARDO CARVALHO" vs "GERARDO CARVALHO DA JUNIOR") e empresa
-- ("ATACADÃO DIA A DIA" vs "DIA A DIA ATACADISTA") sao diferentes —
-- a mesma pessoa, grafada diferente no teste. Funde na mao, com o
-- MESMO criterio de heranca e redirecionamento de referencias que a
-- funcao bulk usa (gestores_historico, indicacoes, jantar_convidados,
-- participantes, prospeccoes, sugestoes_ia — as 6 FKs pra gestores
-- conferidas no schema).
-- =====================================================================

set search_path = gestao, public;

do $$
declare
  v_sobrevive uuid;  -- GERARDO CARVALHO (e-mail corporativo)
  v_perde     uuid;  -- GERARDO CARVALHO DA JUNIOR (teste)
  v_qtd_sobrevive int; v_qtd_perde int;
begin
  select count(*) into v_qtd_sobrevive from gestores where nome = 'GERARDO CARVALHO';
  select count(*) into v_qtd_perde     from gestores where nome = 'GERARDO CARVALHO DA JUNIOR';

  if v_qtd_sobrevive <> 1 then
    raise exception '% gestor(es) "GERARDO CARVALHO" — esperado exatamente 1', v_qtd_sobrevive;
  end if;
  if v_qtd_perde <> 1 then
    raise exception '% gestor(es) "GERARDO CARVALHO DA JUNIOR" — esperado exatamente 1', v_qtd_perde;
  end if;

  select id into v_sobrevive from gestores where nome = 'GERARDO CARVALHO';
  select id into v_perde     from gestores where nome = 'GERARDO CARVALHO DA JUNIOR';

  -- se o sobrevivente ja tiver participante no MESMO evento que o
  -- perdedor, a regra abaixo (colidiu = descarta) apagaria o
  -- contrato que acabamos de resetar pra reenvio — para antes, em vez
  -- de apagar calado.
  if exists (
    select 1 from participantes pa_perde
    join participantes pa_sobrevive
      on pa_sobrevive.evento_id = pa_perde.evento_id
     and pa_sobrevive.gestor_id = v_sobrevive
    where pa_perde.gestor_id = v_perde
  ) then
    raise exception 'GERARDO CARVALHO ja tem participante no mesmo evento que GERARDO CARVALHO DA JUNIOR — fundir apagaria o contrato recem-resetado. Resolva na mao antes de fundir.';
  end if;

  -- o sobrevivente herda o que nao tinha (sem sobrescrever o que ja tem)
  update gestores s set
    email        = coalesce(s.email, p.email),
    telefone     = coalesce(s.telefone, p.telefone),
    cargo        = coalesce(s.cargo, p.cargo),
    cnpj         = coalesce(s.cnpj, p.cnpj),
    cpf          = coalesce(s.cpf, p.cpf),
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

  update gestores_historico set gestor_id = v_sobrevive where gestor_id = v_perde;
  update indicacoes         set gestor_id = v_sobrevive where gestor_id = v_perde;
  update prospeccoes        set gestor_id = v_sobrevive where gestor_id = v_perde;
  update sugestoes_ia       set gestor_id = v_sobrevive where gestor_id = v_perde;

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

  raise notice 'GERARDO CARVALHO DA JUNIOR (%) fundido em GERARDO CARVALHO (%).', v_perde, v_sobrevive;
end $$;
