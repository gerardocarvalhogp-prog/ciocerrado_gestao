-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Normaliza gestores.perfil e funde as duplicatas reais da importacao.
--
-- 1. PERFIL COM PREFIXO NUMERICO
--
-- CADASTRO 2024 guarda perfil como "00 - GESTOR", "15 - ANALISTA",
-- "10 - INFLUENCIADOR", "35 - OPORTUNIDADE" — o codigo da planilha
-- veio junto do texto, e a importacao gravou como veio. CADASTRO 2025
-- usa so o texto limpo ("GESTOR"). Resultado: a mesma categoria vira
-- dois valores diferentes no banco, e todo filtro por perfil ('GESTOR')
-- perde as linhas trazidas por 2024.
--
-- "INFLUENCIADOR" tambem e sinonimo de "INFLUENCER" (grafia usada no
-- resto do banco) — unifica os dois.
--
-- "OPORTUNIDADE" nao e valor de PERFIL na legenda original (essa
-- palavra e de STATUS CADASTRO, nao de PERFIL) — mantido como esta,
-- so sem o prefixo, porque nao ha como saber com seguranca qual
-- categoria de PERFIL a linha deveria ter. Fica marcado aqui para
-- revisao manual futura, nao adivinhado.
--
-- 2. QUATRO DUPLICATAS REAIS
--
-- Mesmo nome (normalizado) E mesma empresa, vindos de fontes de
-- importacao diferentes (CADASTRO 2025 e CADASTRO 2024), cada um com
-- um e-mail diferente — a mesma pessoa, cadastrada duas vezes porque
-- as duas planilhas nao compartilham um identificador comum para essas
-- quatro linhas especificas (o resto da base casou certo por e-mail).
--
-- Sobrevive quem tem mais campos preenchidos; o outro e apagado depois
-- de redirecionar toda referencia (gestores_historico, indicacoes,
-- jantar_convidados, participantes, prospeccoes, sugestoes_ia) e de
-- copiar para o sobrevivente qualquer campo que ele tinha vazio e o
-- perdedor tinha preenchido — nenhum dado se perde, so a linha extra.
--
-- Escopo deliberadamente estreito: SO nome+empresa identicos. Os
-- outros 21 pares de nome igual encontrados na auditoria tem empresa
-- diferente — podem ser homonimos ou troca de emprego entre 2024 e
-- 2025, e decidir errado ali junta duas pessoas diferentes. Fica de
-- fora, para revisao manual.
-- =====================================================================

set search_path = gestao, public;

-- ---------------------------------------------------------------------
-- 1. Perfil
-- ---------------------------------------------------------------------

UPDATE gestores
   SET perfil = upper(trim(regexp_replace(perfil, '^\d+\s*-\s*', '')))
 WHERE perfil ~ '^\d+\s*-\s*';

UPDATE gestores
   SET perfil = 'INFLUENCER'
 WHERE upper(perfil) = 'INFLUENCIADOR';

UPDATE gestores
   SET perfil = upper(perfil)
 WHERE perfil <> upper(perfil);

-- ---------------------------------------------------------------------
-- 2. Funde as 4 duplicatas reais
-- ---------------------------------------------------------------------

do $$
declare
  r record;
  v_sobrevive uuid;
  v_perde uuid;
  v_fundidos int := 0;
begin
  for r in
    select a.id as id1, b.id as id2,
      (case when a.email is not null then 1 else 0 end
       + case when a.telefone is not null then 1 else 0 end
       + case when a.cargo is not null then 1 else 0 end
       + case when a.cnpj is not null then 1 else 0 end
       + case when a.cidade is not null then 1 else 0 end
       + case when a.perfil is not null then 1 else 0 end
       + case when a.linkedin is not null then 1 else 0 end) as score1,
      (case when b.email is not null then 1 else 0 end
       + case when b.telefone is not null then 1 else 0 end
       + case when b.cargo is not null then 1 else 0 end
       + case when b.cnpj is not null then 1 else 0 end
       + case when b.cidade is not null then 1 else 0 end
       + case when b.perfil is not null then 1 else 0 end
       + case when b.linkedin is not null then 1 else 0 end) as score2
    from gestores a
    join gestores b
      on lower(unaccent('unaccent', a.nome)) = lower(unaccent('unaccent', b.nome))
      and a.empresa = b.empresa
      and a.id < b.id
  loop
    if r.score1 >= r.score2 then
      v_sobrevive := r.id1; v_perde := r.id2;
    else
      v_sobrevive := r.id2; v_perde := r.id1;
    end if;

    -- copia pro sobrevivente o que ele nao tinha e o perdedor tinha
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
      posicao_gestor = coalesce(s.posicao_gestor, p.posicao_gestor)
    from gestores p
    where s.id = v_sobrevive and p.id = v_perde;

    -- redireciona toda referencia antes de apagar
    update gestores_historico set gestor_id = v_sobrevive where gestor_id = v_perde;
    update indicacoes         set gestor_id = v_sobrevive where gestor_id = v_perde;
    update jantar_convidados  set gestor_id = v_sobrevive where gestor_id = v_perde;
    update participantes      set gestor_id = v_sobrevive where gestor_id = v_perde;
    update prospeccoes        set gestor_id = v_sobrevive where gestor_id = v_perde;
    update sugestoes_ia       set gestor_id = v_sobrevive where gestor_id = v_perde;

    delete from gestores where id = v_perde;
    v_fundidos := v_fundidos + 1;
  end loop;

  raise notice '% duplicata(s) fundida(s)', v_fundidos;
end $$;
