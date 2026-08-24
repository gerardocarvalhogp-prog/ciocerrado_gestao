-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- funcoes-base-helpers.sql  ·  os quatro helpers que a cadeia perdeu
--
-- Rodar DEPOIS de schema.sql e schema-extra.sql, e ANTES de
-- funcoes-pesquisa.sql (o primeiro arquivo da cadeia que os usa).
--
-- POR QUE ESTE ARQUIVO EXISTE
--
-- A cadeia funcoes-pesquisa > migracao-02 > funcoes-prospeccao >
-- funcoes-etiquetas > funcoes-financeiro > migracao-03 > correcoes-01 >
-- migracao-04 > 05 > 06 chama quatro helpers:
--
--   _exige_admin()            _exige_staff()
--   _exige_patrocinador(uuid) _meu_participante(text)
--
-- Nenhum arquivo presente na pasta os define. Eles viviam nos arquivos
-- de funcao base (funcoes-patro / funcoes-part / funcoes-admin /
-- funcoes-checkin), que sumiram da pasta - e por isso a cadeia inteira
-- nao roda hoje: o primeiro CREATE FUNCTION que os referencia ate passa,
-- mas a primeira CHAMADA quebra com "function _exige_admin() does not
-- exist".
--
-- Aqui eles voltam com o mesmo comportamento, escritos sobre as funcoes
-- que o schema.sql ja tem (is_admin, is_staff, meus_patrocinadores).
-- Nao substituem nada: se os arquivos base originais reaparecerem, este
-- arquivo pode ser descartado.
-- =====================================================================

set search_path = gestao, public;

-- Barra quem nao e admin. Levanta excecao em vez de devolver false: a
-- cadeia usa "perform _exige_admin()", que descarta o retorno - se
-- fosse boolean, a checagem passaria despercebida.
create or replace function _exige_admin()
returns void language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  if not is_admin() then
    raise exception 'Acao restrita a administradores.'
      using errcode = '42501';
  end if;
end;
$$;

-- 'staff' cobre a operacao do dia (check-in, etiquetas, alocacao de
-- quarto). Admin tambem passa: is_staff() so exige estar em admins e
-- ativo, sem olhar o papel.
create or replace function _exige_staff()
returns void language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  if not is_staff() then
    raise exception 'Acao restrita a equipe.'
      using errcode = '42501';
  end if;
end;
$$;

-- O usuario logado responde por este patrocinador? Staff passa direto -
-- e a organizacao operando o portal em nome da empresa.
create or replace function _exige_patrocinador(p_patrocinador_id uuid)
returns void language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  if p_patrocinador_id is null then
    raise exception 'Patrocinador nao informado.';
  end if;
  if not pode_ver_patrocinador(p_patrocinador_id) then
    raise exception 'Sem acesso a este patrocinador.'
      using errcode = '42501';
  end if;
end;
$$;

-- Participante do usuario logado neste evento.
--
-- O e-mail vem do JWT, nunca de parametro: sem isso daria para pedir o
-- rooming de outra pessoa trocando um id na chamada.
create or replace function _meu_participante(p_evento_slug text)
returns uuid language sql stable security definer
set search_path = gestao, public as $$
  select pa.id
  from participantes pa
  join gestores g on g.id = pa.gestor_id
  join eventos e  on e.id = pa.evento_id
  where e.slug = p_evento_slug
    and g.email_norm = norm_doc(auth.jwt() ->> 'email')
  limit 1;
$$;

revoke execute on function _exige_admin()          from anon;
revoke execute on function _exige_staff()          from anon;
revoke execute on function _exige_patrocinador(uuid) from anon;
revoke execute on function _meu_participante(text) from anon;
