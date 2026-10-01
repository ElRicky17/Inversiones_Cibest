import json
from django.shortcuts import render
from django.db.models import Max
from .models import PortafolioCOP, PortafolioUSD

def dashboard_view(request):
    # 1. Obtener lista de clientes únicos (de ambas vistas)
    clientes_cop = set(PortafolioCOP.objects.values_list('id_sistema_cliente', flat=True).distinct())
    clientes_usd = set(PortafolioUSD.objects.values_list('id_sistema_cliente', flat=True).distinct())
    lista_clientes = sorted(list(clientes_cop.union(clientes_usd)))

    cliente_selected = request.GET.get('cliente', lista_clientes[0] if lista_clientes else None)

    datos_cop = []
    datos_usd = []
    ultima_fecha_cop = None
    ultima_fecha_usd = None

    if cliente_selected:
        # --- PORTAFOLIO COP (Última fecha disponible para este cliente) ---
        max_fecha_cop = PortafolioCOP.objects.filter(
            id_sistema_cliente=cliente_selected
        ).aggregate(Max('fecha_corte'))['fecha_corte__max']

        if max_fecha_cop:
            ultima_fecha_cop = max_fecha_cop.strftime('%Y-%m-%d')
            qs_cop = PortafolioCOP.objects.filter(
                id_sistema_cliente=cliente_selected,
                fecha_corte=max_fecha_cop
            )
            datos_cop = [
                {
                    'nombre_activo': item.nombre_activo,
                    'macroactivo': item.macroactivo,
                    'saldo_cop': float(item.saldo_cop or 0)
                }
                for item in qs_cop
            ]

        # --- PORTAFOLIO USD (Última fecha disponible para este cliente) ---
        max_fecha_usd = PortafolioUSD.objects.filter(
            id_sistema_cliente=cliente_selected
        ).aggregate(Max('fecha_corte'))['fecha_corte__max']

        if max_fecha_usd:
            ultima_fecha_usd = max_fecha_usd.strftime('%Y-%m-%d')
            qs_usd = PortafolioUSD.objects.filter(
                id_sistema_cliente=cliente_selected,
                fecha_corte=max_fecha_usd
            )
            datos_usd = [
                {
                    'nombre_activo': item.nombre_activo,
                    'simbol': item.simbol or 'N/A',
                    'saldo_usd': float(item.saldo_usd or 0)
                }
                for item in qs_usd
            ]

    context = {
        'clientes': lista_clientes,
        'cliente_selected': cliente_selected,
        'datos_cop_json': json.dumps(datos_cop),
        'datos_usd_json': json.dumps(datos_usd),
        'ultima_fecha_cop': ultima_fecha_cop,
        'ultima_fecha_usd': ultima_fecha_usd,
    }
    return render(request, 'portafolio/dashboard.html', context)