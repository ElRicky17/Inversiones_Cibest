from django.db import models


class PortafolioCOP(models.Model):
    """Lee vista_portafolio_cop_ultimo (última fecha disponible por cliente).

    Django exige una PK; en la vista id_sistema_cliente NO es único, por eso
    estos modelos se consultan siempre con .values() y nunca por instancia.
    """
    id_sistema_cliente = models.CharField(max_length=50, primary_key=True)
    fecha_corte = models.DateField()
    id_aproximado = models.BooleanField(default=False)
    cod_activo = models.CharField(max_length=50, null=True)
    nombre_activo = models.CharField(max_length=255)
    macroactivo = models.CharField(max_length=100)
    perfil_riesgo = models.CharField(max_length=100)
    banca = models.CharField(max_length=100)
    saldo_cop = models.DecimalField(max_digits=24, decimal_places=2)

    class Meta:
        managed = False
        db_table = 'vista_portafolio_cop_ultimo'


class PortafolioUSD(models.Model):
    """Lee vista_portafolio_usd_ultimo (última fecha disponible por cliente)."""
    id_sistema_cliente = models.CharField(max_length=50, primary_key=True)
    fecha_corte = models.DateField()
    id_aproximado = models.BooleanField(default=False)
    simbolo = models.CharField(max_length=50, null=True)
    cusip = models.CharField(max_length=50, null=True)
    isin = models.CharField(max_length=50, null=True)
    nombre_activo = models.CharField(max_length=255)
    tipo_activo = models.CharField(max_length=50)
    cantidad = models.DecimalField(max_digits=24, decimal_places=4, null=True)
    saldo_usd = models.DecimalField(max_digits=24, decimal_places=2)
    fecha_vencimiento = models.DateField(null=True)
    tasa_cupon = models.DecimalField(max_digits=12, decimal_places=4, null=True)

    class Meta:
        managed = False
        db_table = 'vista_portafolio_usd_ultimo'