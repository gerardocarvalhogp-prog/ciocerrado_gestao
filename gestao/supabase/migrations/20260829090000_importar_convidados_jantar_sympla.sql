-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Importa convidados de jantar a partir de planilha do Sympla.
--
-- O BURACO
--
-- jantares.sympla_url (20260828110000) so guarda o link de INSCRICAO —
-- para onde a organizacao manda o convidado se inscrever. Nao existia
-- nenhum caminho de volta: quem se inscreveu pelo Sympla nunca virava
-- linha em jantar_convidados sozinho. Com 40+ jantares avulsos por ano
-- (README §6, "Jantares sao modulo separado"), cada um podendo ter sua
-- propria pagina de inscricao no Sympla, isso e trabalho manual —
-- passar lista um a um pelo formulario avulso — em volume real.
--
-- O mesmo buraco ja tinha sido fechado para o evento principal em
-- 20260828120000 (admin_importar_participantes_sympla). Esta migration
-- e a mesma ideia para jantar_convidados: mesmo formato de planilha
-- (mesma plataforma, mesmas colunas de export), mesma logica de
-- casar/criar gestor por e-mail, mesma decisao de estado de pagamento
-- manda.
--
-- DECISOES DE COMPORTAMENTO (espelhando 20260828120000)
--
-- Estado de pagamento manda: so 'aprovado' confirma. 'cancelado' NAO
-- cria ninguem, mas rebaixa quem ja estava para 'recusado' — senao um
-- cancelamento no Sympla deixaria um fantasma "confirmado" na lista do
-- jantar.
--
-- E-mail corporativo tem prioridade sobre o e-mail da conta Sympla,
-- pelo mesmo motivo: e o que casa com a base de gestores que ja existe.
--
-- SEM TRAVA DE CAPACIDADE NA IMPORTACAO. jantar_adicionar_convidados_
-- existentes (a adicao manual) trava porque e uma escolha curada, "cabe
-- mais esse?". Importacao do Sympla e fato consumado — a pessoa ja
-- comprou o ingresso antes de qualquer decisao daqui. Bloquear metade
-- da planilha por causa de uma capacidade desatualizada no cadastro
-- esconderia gente que realmente vai aparecer. A funcao devolve
-- ocupacao vs capacidade para a tela avisar, sem impedir.
--
-- STATUS NUNCA REGRIDE. Reimportar depois do check-in nao pode voltar
-- 'compareceu' para 'confirmado' — a pessoa ja chegou, isso e fato mais
-- forte que uma linha de planilha reprocessada.
--
-- Reimportar e seguro: gestores casa por email_norm, jantar_convidados
-- tem unique (jantar_id, gestor_id), sympla_id fica gravado para rastro.
-- =====================================================================

set search_path = gestao, public;

ALTER TABLE "gestao"."jantar_convidados" ADD COLUMN IF NOT EXISTS "sympla_id" "text";

ALTER TABLE "gestao"."jantar_convidados" DROP CONSTRAINT IF EXISTS "jantar_convidados_origem_check";
ALTER TABLE "gestao"."jantar_convidados" ADD CONSTRAINT "jantar_convidados_origem_check"
  CHECK (origem = ANY (ARRAY['prospeccao'::text, 'avulso'::text, 'manual'::text, 'sympla'::text]));


CREATE OR REPLACE FUNCTION "gestao"."jantar_importar_convidados_sympla"(
  "p_jantar_id" "uuid", "p_linhas" "jsonb"
) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare
  v_cap int;
  v_item jsonb;
  v_email text; v_nome text; v_pgto text;
  v_gestor uuid; v_linha int := 0;
  v_criados int := 0; v_atualizados int := 0; v_recusados int := 0; v_erros int := 0;
  v_gestores_novos int := 0;
  v_erros_det jsonb := '[]'::jsonb;
  v_imp uuid;
  v_existia boolean; v_status_atual text;
begin
  perform _exige_admin();

  select capacidade into v_cap from jantares where id = p_jantar_id;
  if v_cap is null then
    raise exception 'Jantar nao encontrado' using errcode='P0002';
  end if;

  insert into importacoes (tipo, total_linhas, executado_por)
  values ('jantar_convidados_sympla',
          jsonb_array_length(coalesce(p_linhas,'[]'::jsonb)),
          auth.jwt() ->> 'email')
  returning id into v_imp;

  for v_item in select * from jsonb_array_elements(coalesce(p_linhas,'[]'::jsonb))
  loop
    v_linha := v_linha + 1;

    v_nome := nullif(trim(coalesce(v_item ->> 'nome','')), '');
    v_email := nullif(lower(trim(coalesce(
                 nullif(trim(coalesce(v_item ->> 'email_corporativo','')),''),
                 v_item ->> 'email'))), '');
    v_pgto  := lower(trim(coalesce(v_item ->> 'estado_pagamento','')));

    if v_nome is null then
      v_erros := v_erros + 1;
      v_erros_det := v_erros_det || jsonb_build_object('linha', v_linha, 'motivo', 'linha sem nome');
      continue;
    end if;

    if v_email is null then
      v_erros := v_erros + 1;
      v_erros_det := v_erros_det || jsonb_build_object('linha', v_linha, 'motivo', 'sem e-mail', 'nome', v_nome);
      continue;
    end if;

    if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
      v_erros := v_erros + 1;
      v_erros_det := v_erros_det || jsonb_build_object(
        'linha', v_linha, 'motivo', 'e-mail invalido: ' || v_email, 'nome', v_nome);
      continue;
    end if;

    select g.id into v_gestor from gestores g where g.email_norm = norm_doc(v_email);

    if v_gestor is null then
      insert into gestores (nome, email, empresa, cargo, telefone, cnpj, cpf, origem)
      values (v_nome, v_email,
              nullif(trim(regexp_replace(coalesce(v_item ->> 'empresa',''), '^\d+\s*-\s*', '')), ''),
              nullif(trim(coalesce(v_item ->> 'cargo','')), ''),
              nullif(trim(coalesce(v_item ->> 'telefone','')), ''),
              nullif(trim(coalesce(v_item ->> 'cnpj','')), ''),
              nullif(trim(coalesce(v_item ->> 'cpf','')), ''),
              'importacao')
      returning id into v_gestor;
      v_gestores_novos := v_gestores_novos + 1;
    else
      update gestores set
        empresa  = coalesce(empresa,  nullif(trim(regexp_replace(coalesce(v_item ->> 'empresa',''), '^\d+\s*-\s*', '')), '')),
        cargo    = coalesce(cargo,    nullif(trim(coalesce(v_item ->> 'cargo','')), '')),
        telefone = coalesce(telefone, nullif(trim(coalesce(v_item ->> 'telefone','')), '')),
        cnpj     = coalesce(cnpj,     nullif(trim(coalesce(v_item ->> 'cnpj','')), '')),
        cpf      = coalesce(cpf,      nullif(trim(coalesce(v_item ->> 'cpf','')), ''))
      where id = v_gestor;
    end if;

    select exists(select 1 from jantar_convidados where jantar_id = p_jantar_id and gestor_id = v_gestor),
           status
      into v_existia, v_status_atual
      from jantar_convidados where jantar_id = p_jantar_id and gestor_id = v_gestor;

    if v_pgto = 'cancelado' then
      -- nao cria ninguem por cancelamento; so rebaixa quem ja estava,
      -- e nunca por cima de quem ja compareceu (fato mais forte)
      if v_existia and v_status_atual <> 'compareceu' then
        update jantar_convidados set status = 'recusado', sympla_id = coalesce(
             nullif(trim(coalesce(v_item ->> 'sympla_id','')), ''), sympla_id)
         where jantar_id = p_jantar_id and gestor_id = v_gestor;
        v_recusados := v_recusados + 1;
      end if;
      continue;
    end if;

    if v_pgto <> 'aprovado' then
      v_erros := v_erros + 1;
      v_erros_det := v_erros_det || jsonb_build_object(
        'linha', v_linha, 'nome', v_nome,
        'motivo', 'estado de pagamento nao reconhecido: ' ||
                  coalesce(nullif(v_pgto,''),'(vazio)'));
      continue;
    end if;

    if v_existia and v_status_atual = 'compareceu' then
      -- ja chegou no jantar; so atualiza o rastro do sympla_id, status fica
      update jantar_convidados set
        sympla_id = coalesce(nullif(trim(coalesce(v_item ->> 'sympla_id','')), ''), sympla_id)
      where jantar_id = p_jantar_id and gestor_id = v_gestor;
      v_atualizados := v_atualizados + 1;
      continue;
    end if;

    insert into jantar_convidados (jantar_id, gestor_id, empresa, origem, status, sympla_id)
    select p_jantar_id, v_gestor, g.empresa, 'sympla', 'confirmado',
           nullif(trim(coalesce(v_item ->> 'sympla_id','')), '')
      from gestores g where g.id = v_gestor
    on conflict (jantar_id, gestor_id) do update set
      status    = 'confirmado',
      sympla_id = coalesce(excluded.sympla_id, jantar_convidados.sympla_id);

    if v_existia then v_atualizados := v_atualizados + 1;
    else                 v_criados := v_criados + 1;
    end if;
  end loop;

  update importacoes set criados = v_criados, atualizados = v_atualizados,
                         erros = v_erros
   where id = v_imp;

  return jsonb_build_object(
    'ok', true,
    'criados', v_criados,
    'atualizados', v_atualizados,
    'recusados', v_recusados,
    'gestores_novos', v_gestores_novos,
    'erros', v_erros,
    'detalhe_erros', v_erros_det,
    'capacidade', v_cap,
    'ocupados_agora', (select count(*) from jantar_convidados
                        where jantar_id = p_jantar_id and status in ('confirmado','compareceu')));
end;
$$;

REVOKE ALL ON FUNCTION "gestao"."jantar_importar_convidados_sympla"("uuid","jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."jantar_importar_convidados_sympla"("uuid","jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."jantar_importar_convidados_sympla"("uuid","jsonb") TO "service_role";
