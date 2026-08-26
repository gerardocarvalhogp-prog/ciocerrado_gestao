-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Os quartos da cota nascem junto com o patrocinador.
--
-- O QUE ACONTECIA
--
-- Cadastrar um patrocinador criava a empresa e mais nada. Os quartos da
-- cota so apareciam quando alguem lembrava de apertar "Gerar quartos
-- das cotas", na aba Estrutura. Quem cadastrava uma empresa nova via
-- ela na lista sem quarto nenhum, e o patrocinador entrava no portal e
-- lia "sua cota ainda nao tem quartos liberados" — sem ninguem ter
-- errado nada.
--
-- Era um passo separado que nao precisa existir: se a empresa tem cota,
-- os quartos daquela cota sao consequencia, nao decisao.
--
-- A GERACAO E IDEMPOTENTE
--
-- `admin_gerar_quartos_cota` cria so o que falta para bater com a
-- composicao da cota. Salvar a mesma empresa dez vezes nao duplica
-- nada. Trocar para uma cota maior faz os quartos que faltam
-- aparecerem no proximo save.
--
-- DIMINUIR NAO APAGA. Cota menor nao remove quarto, porque pode ja ter
-- gente dentro — continua sendo decisao manual, na tela de quartos.
-- =====================================================================

set search_path = gestao, public;

CREATE OR REPLACE FUNCTION gestao.admin_salvar_patrocinador(p_evento_slug text, p_empresa text, p_cota_nome text DEFAULT NULL::text, p_cnpj text DEFAULT NULL::text, p_segmento text DEFAULT NULL::text, p_o_que_vende text DEFAULT NULL::text, p_quartos_extras integer DEFAULT 0, p_vagas_mesa_override integer DEFAULT NULL::integer, p_status text DEFAULT 'ativo'::text, p_site text DEFAULT NULL::text, p_resumo text DEFAULT NULL::text, p_natureza text DEFAULT NULL::text, p_cidade text DEFAULT NULL::text, p_estado text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
declare v_evento uuid; v_cota uuid; v_id uuid;
begin
  perform _exige_admin();

  select id into v_evento from eventos where slug = p_evento_slug;
  if v_evento is null then
    raise exception 'Evento nao encontrado' using errcode='P0002';
  end if;
  if coalesce(trim(p_empresa),'') = '' then
    raise exception 'Informe o nome da empresa' using errcode='22023';
  end if;

  if p_cota_nome is not null and trim(p_cota_nome) <> '' then
    select id into v_cota from cotas
     where evento_id = v_evento and lower(nome) = lower(trim(p_cota_nome));
    if v_cota is null then
      raise exception 'Cota "%" nao existe neste evento', p_cota_nome
        using errcode='P0002';
    end if;
  end if;

  insert into patrocinadores (evento_id, cota_id, empresa, cnpj, segmento,
                              o_que_vende, quartos_extras_cota,
                              vagas_mesa_override, status,
                              site, resumo, natureza, cidade, estado)
  values (v_evento, v_cota, trim(p_empresa), p_cnpj, p_segmento,
          p_o_que_vende, coalesce(p_quartos_extras,0),
          p_vagas_mesa_override, p_status,
          p_site, p_resumo, p_natureza, p_cidade, p_estado)
  on conflict (evento_id, lower(empresa)) do update set
    cota_id = coalesce(excluded.cota_id, patrocinadores.cota_id),
    cnpj = coalesce(excluded.cnpj, patrocinadores.cnpj),
    segmento = coalesce(excluded.segmento, patrocinadores.segmento),
    o_que_vende = coalesce(excluded.o_que_vende, patrocinadores.o_que_vende),
    quartos_extras_cota = excluded.quartos_extras_cota,
    vagas_mesa_override = excluded.vagas_mesa_override,
    status = excluded.status,
    site = coalesce(excluded.site, patrocinadores.site),
    resumo = coalesce(excluded.resumo, patrocinadores.resumo),
    natureza = coalesce(excluded.natureza, patrocinadores.natureza),
    cidade = coalesce(excluded.cidade, patrocinadores.cidade),
    estado = coalesce(excluded.estado, patrocinadores.estado)
  returning id into v_id;

  -- Os quartos da cota nascem com a empresa. Antes dependiam do botao
  -- "Gerar quartos das cotas", e quem cadastrava um patrocinador novo
  -- via a empresa criada e nenhum quarto — o patrocinador entrava no
  -- portal e lia "sua cota ainda nao tem quartos liberados".
  --
  -- A geracao e idempotente: cria so o que falta para bater com a
  -- composicao da cota, entao salvar de novo nao duplica. Se a cota
  -- mudar para uma maior, os quartos que faltam aparecem no proximo
  -- save; diminuir NAO apaga quarto, porque pode ja ter gente dentro —
  -- isso continua sendo decisao manual.
  if v_id is not null and coalesce(p_status,'ativo') = 'ativo' then
    declare v_tem_cota boolean;
    begin
      select cota_id is not null into v_tem_cota
      from patrocinadores where id = v_id;
      if v_tem_cota then
        perform admin_gerar_quartos_cota(v_id);
      end if;
    end;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id,
    'quartos', (select count(*) from reservas r
                 where r.patrocinador_id = v_id and r.status <> 'cancelado'));
end;
$function$;
