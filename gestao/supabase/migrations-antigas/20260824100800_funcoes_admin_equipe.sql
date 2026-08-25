-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- funcoes-admin-config.sql  ·  precos e equipe
--
-- Roda DEPOIS de funcoes-admin.sql.
-- =====================================================================

set search_path = gestao, public;

-- =====================================================================
-- 1. PRECOS
--
-- acompanhante_adulto, crianca e transfer sao lidos POR NOME no calculo
-- da fatura. Remover um deles quebraria a conta em silencio, entao a
-- remocao e recusada aqui. Para nao cobrar, deixe o valor em zero.
-- =====================================================================


-- =====================================================================
-- 2. EQUIPE
--
-- 'admin' faz tudo; 'staff' e a operacao do dia (check-in, etiquetas,
-- alocacao de quarto) sem cadastro nem financeiro. Vale para todos os
-- eventos - a tela deixa isso explicito com o selo "todos os eventos".
-- =====================================================================

create or replace function admin_listar_equipe()
returns table (id uuid, email text, nome text, role text,
               ativo boolean, created_at timestamptz)
language plpgsql stable security definer set search_path = gestao, public as $$
begin
  perform exigir_admin();
  return query
  select a.id, a.email, a.nome, a.role, a.ativo, a.created_at
  from admins a
  where a.ativo
  order by a.role, a.email;
end;
$$;

create or replace function admin_salvar_membro(
  p_email text, p_nome text default null, p_role text default 'staff'
)
returns jsonb
language plpgsql security definer set search_path = gestao, public as $$
declare v_id uuid;
begin
  perform exigir_admin();

  p_email := nullif(trim(coalesce(p_email,'')),'');
  if p_email is null then raise exception 'Informe o e-mail.'; end if;
  if norm_doc(p_email) !~ '^[^@]+@[^@]+\.[^@]+$' then
    raise exception 'E-mail invalido.';
  end if;
  if coalesce(p_role,'staff') not in ('admin','staff') then
    raise exception 'Perfil invalido.';
  end if;

  insert into admins (email, nome, role, ativo)
  values (p_email, p_nome, coalesce(p_role,'staff'), true)
  on conflict (email_norm) do update
    set nome  = coalesce(excluded.nome, admins.nome),
        role  = excluded.role,
        ativo = true
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

-- Remove o acesso, mas nao deixa o sistema ficar sem dono: o ultimo
-- admin ativo nao sai, e ninguem se remove sozinho (a tela ja esconde o
-- botao, mas a regra tem de valer no banco).
create or replace function admin_remover_membro(p_id uuid)
returns jsonb
language plpgsql security definer set search_path = gestao, public as $$
declare
  m record;
  v_admins int;
begin
  perform exigir_admin();

  select * into m from admins where id = p_id;
  if m.id is null then raise exception 'Membro nao encontrado.'; end if;

  if m.email_norm = norm_doc(auth.jwt() ->> 'email') then
    raise exception 'Voce nao pode remover o proprio acesso.';
  end if;

  if m.role = 'admin' then
    select count(*) into v_admins from admins
    where role = 'admin' and ativo and id <> p_id;
    if v_admins = 0 then
      raise exception 'Este e o ultimo administrador ativo: promova outro antes de remove-lo.';
    end if;
  end if;

  update admins set ativo = false where id = p_id;
  return jsonb_build_object('ok', true);
end;
$$;

-- =====================================================================
-- 3. PERMISSOES
-- =====================================================================
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'gestao' and p.proname like 'admin%'
  loop
    execute format('revoke execute on function %s from anon', f.sig);
  end loop;
end $$;
