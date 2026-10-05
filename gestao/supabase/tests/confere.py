"""Roda testes da familia transacional e confere o resultado sozinho.

    python supabase/tests/confere.py supabase/tests/1[3-9]-*.sql supabase/tests/2*.sql
    python supabase/tests/confere.py supabase/tests/19-jantares-e-atividades.sql -v

Le a saida do psql seguindo o formato dos testes (ver LEIA-ME):

  - "-- ... deve FALHAR": tem que vir um ERROR antes do proximo marcador.
    Erro de sintaxe, "transaction is aborted", savepoint inexistente ou
    "permission denied for table" NAO contam — sao defeito do teste, nao
    a recusa que se queria provar.
  - "-- ... deve PASSAR": nenhum ERROR, e toda coluna cujo nome termina em
    _ok tem que vir t/true. f, nulo ou zero linhas = problema.
  - "-- ACHADO ...": comportamento registrado pra decisao do organizador;
    o que vier ali e listado, nao conta como passou nem falhou.

-v imprime a saida inteira do psql. Sai com codigo 1 se algum arquivo
tiver problema.
"""
import re
import subprocess
import sys

CONTAINER = 'supabase_db_gestao-cio-cerrado'
RUIM = (r'syntax error|transaction is aborted|savepoint .* does not exist'
        r'|permission denied for (table|view|schema|sequence)|variable|does not exist')


def rodar(arquivo):
    with open(arquivo, 'rb') as f:
        sql = f.read()
    return subprocess.run(
        ['docker', 'exec', '-i', CONTAINER, 'sh', '-c', 'psql -U postgres -d postgres -q 2>&1'],
        input=sql, capture_output=True).stdout.decode('utf-8', 'replace')


def conferir(out):
    problemas, achados, recusas = [], [], []
    esperado, pendente, rotulo, cab, n_ok = None, False, '', None, 0
    linhas = out.splitlines()
    for i, l in enumerate(linhas):
        s = l.strip()
        if l.startswith('-- ACHADO') or (l.startswith('-- ') and ('deve FALHAR' in l or 'deve PASSAR' in l)):
            if pendente:
                problemas.append(f'NAO FALHOU: {rotulo}')
            rotulo = l
            esperado = 'ACHADO' if l.startswith('-- ACHADO') else ('FAIL' if 'deve FALHAR' in l else 'PASS')
            pendente = esperado == 'FAIL'
            if esperado == 'ACHADO':
                achados.append(l)
            cab = None
            continue
        if l.startswith('ERROR:'):
            cab = None
            if esperado == 'ACHADO':
                achados.append('      -> ' + l)
            elif pendente and not re.search(RUIM, l):
                pendente = False
                recusas.append(f'{rotulo}\n      -> {l}')
            else:
                problemas.append(f'ERRO INESPERADO ({rotulo}): {l}')
            continue
        if re.fullmatch(r'-+(\+-+)*', s) and i > 0:
            cab = [c.strip() for c in linhas[i - 1].split('|')]
            continue
        if re.fullmatch(r'\(\d+ rows?\)', s):
            if s == '(0 rows)' and esperado == 'PASS' and cab and any(c.endswith('_ok') for c in cab):
                problemas.append(f'ZERO LINHAS (a checagem nao rodou): {rotulo}')
            cab = None
            continue
        if cab:
            for nome, v in zip(cab, (c.strip() for c in l.split('|'))):
                if not nome.endswith('_ok'):
                    continue
                if v in ('t', 'true'):
                    n_ok += 1
                elif esperado == 'ACHADO':
                    achados.append(f'      -> {nome} = {v or "nulo"}')
                else:
                    tipo = 'FALSA' if v in ('f', 'false') else 'NULA'
                    problemas.append(f'CHECAGEM {tipo}: {nome} ({rotulo})')
    if pendente:
        problemas.append(f'NAO FALHOU: {rotulo}')
    return problemas, achados, recusas, n_ok


def main():
    sys.stdout.reconfigure(encoding='utf-8')
    detalhe = '-v' in sys.argv
    arquivos = [a for a in sys.argv[1:] if a != '-v']
    algum_problema = False
    for arquivo in arquivos:
        out = rodar(arquivo)
        problemas, achados, recusas, n_ok = conferir(out)
        print(f'\n=== {arquivo}')
        if detalhe:
            print(out)
            print('\n'.join('  ok  ' + r for r in recusas))
        print(f'{len(recusas)} recusas esperadas, {n_ok} checagens _ok verdadeiras')
        if achados:
            print('ACHADOS (registrados, nao contam como passou/falhou):')
            print('\n'.join('  ' + a for a in achados))
        if problemas:
            algum_problema = True
            print('PROBLEMAS:')
            print('\n'.join('  !! ' + p for p in problemas))
        else:
            print('TUDO BATEU')
    sys.exit(1 if algum_problema else 0)


if __name__ == '__main__':
    main()
