import json
from collections import defaultdict

from django.shortcuts import render

from .models import PortafolioCOP, PortafolioUSD


def _agrupar(filas, claves, saldo):
    """Suma saldos por las claves dadas (evita filas repetidas en los gráficos)."""
    acc = defaultdict(float)
    for f in filas:
        acc[tuple(f[k] for k in claves)] += float(f[saldo] or 0)
    return [dict(zip(claves, k), **{saldo: v}) for k, v in acc.items()]


def dashboard_view(request):
    # Las tablas materializadas son pequeñas e indexadas: 4 consultas livianas en total
    ids = set(PortafolioCOP.objects.values_list('id_sistema_cliente', flat=True))
    ids |= set(PortafolioUSD.objects.values_list('id_sistema_cliente', flat=True))
    normales = sorted(i for i in ids if not i.startswith('SCI-'))
    aproximados = sorted(i for i in ids if i.startswith('SCI-'))

    cliente = request.GET.get('cliente')
    if cliente not in ids:
        cliente = (normales + aproximados or [None])[0]

    datos_cop, datos_usd = [], []
    fecha_cop = fecha_usd = perfil = banca = None

    if cliente:
        filas = list(PortafolioCOP.objects.filter(id_sistema_cliente=cliente).values(
            'fecha_corte', 'nombre_activo', 'macroactivo', 'perfil_riesgo', 'banca', 'saldo_cop'))
        if filas:
            fecha_cop = filas[0]['fecha_corte'].strftime('%Y-%m-%d')
            perfil, banca = filas[0]['perfil_riesgo'], filas[0]['banca']
            datos_cop = _agrupar(filas, ['nombre_activo', 'macroactivo'], 'saldo_cop')

        filas = list(PortafolioUSD.objects.filter(id_sistema_cliente=cliente).values(
            'fecha_corte', 'nombre_activo', 'saldo_usd'))
        if filas:
            fecha_usd = filas[0]['fecha_corte'].strftime('%Y-%m-%d')
            datos_usd = _agrupar(filas, ['nombre_activo'], 'saldo_usd')

    return render(request, 'portafolio/dashboard.html', {
        'clientes': normales,
        'clientes_aprox': aproximados,
        'cliente_selected': cliente,
        'datos_cop_json': json.dumps(datos_cop),
        'datos_usd_json': json.dumps(datos_usd),
        'ultima_fecha_cop': fecha_cop,
        'ultima_fecha_usd': fecha_usd,
        'perfil': perfil,
        'banca': banca,
        'id_aproximado': bool(cliente and cliente.startswith('SCI-')),
    })