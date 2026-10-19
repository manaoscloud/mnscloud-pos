import 'package:flutter/widgets.dart';

/// UI strings in pt-BR (default), en-US and es-ES. Server messages are English: the ones an
/// operator meets are translated by [S.message]; any other is shown as sent.
class S {
  S(this.lang);
  final String lang;

  static S of(BuildContext context) {
    final code = Localizations.maybeLocaleOf(context)?.languageCode ?? 'pt';
    return S(const {'en', 'es'}.contains(code) ? code : 'pt');
  }

  String t(String key) => (_strings[key]?[lang]) ?? (_strings[key]?['pt']) ?? key;

  /// Server or controller message (English) in the operator language. Matching ignores case and
  /// the final period; a prefix match keeps the detail after it (e.g. a failure reason).
  String message(String text) {
    if (lang == 'en') return text;
    final normalized = text.trim().replaceAll(RegExp(r'\.$'), '').toLowerCase();
    for (final entry in _messages.entries) {
      final key = entry.key.toLowerCase();
      if (normalized == key) return entry.value[lang] ?? text;
      if (normalized.startsWith('$key:')) {
        return '${entry.value[lang]}: ${text.trim().substring(entry.key.length + 1).trim()}';
      }
    }
    return text;
  }

  static const Map<String, Map<String, String>> _messages = {
    'No item uses this code': {'pt': 'Nenhum item usa este código.', 'es': 'Ningún artículo usa este código.'},
    'Discount above the terminal limit': {'pt': 'Desconto acima do limite do caixa.', 'es': 'Descuento por encima del límite de la caja.'},
    'Discount exceeds the maximum allowed by the terminal': {'pt': 'Desconto acima do limite do caixa.', 'es': 'Descuento por encima del límite de la caja.'},
    'A sale is waiting for the server confirmation': {'pt': 'Uma venda aguarda a confirmação do servidor.', 'es': 'Una venta espera la confirmación del servidor.'},
    'A sale is still being confirmed. Wait for it before signing out': {'pt': 'Uma venda ainda está sendo confirmada. Aguarde antes de sair.', 'es': 'Una venta aún se está confirmando. Espere antes de salir.'},
    'The sale was not confirmed by the server. Check the connection and try again': {'pt': 'A venda não foi confirmada pelo servidor. Verifique a conexão e tente de novo', 'es': 'El servidor no confirmó la venta. Revise la conexión e intente de nuevo'},
    'Signed out on this screen, but the server session could not be ended': {'pt': 'Você saiu nesta tela, mas não foi possível encerrar a sessão no servidor', 'es': 'Salió en esta pantalla, pero no se pudo cerrar la sesión en el servidor'},
    'Withdrawal exceeds the cash in the drawer': {'pt': 'A sangria é maior que o dinheiro no caixa.', 'es': 'El retiro supera el efectivo de la caja.'},
    'Cash movement amount must be greater than zero': {'pt': 'O valor deve ser maior que zero.', 'es': 'El monto debe ser mayor que cero.'},
    'Counted cash is required to close the session': {'pt': 'Informe o dinheiro contado para fechar o caixa.', 'es': 'Informe el efectivo contado para cerrar la caja.'},
    'Opening amount must be zero or greater': {'pt': 'O fundo de troco não pode ser negativo.', 'es': 'El fondo de cambio no puede ser negativo.'},
    'The terminal already has an open cash session': {'pt': 'Este caixa já está aberto.', 'es': 'Esta caja ya está abierta.'},
    'Open cash session not found': {'pt': 'Não há caixa aberto.', 'es': 'No hay caja abierta.'},
    'Open cash session of the terminal not found': {'pt': 'Não há caixa aberto neste terminal.', 'es': 'No hay caja abierta en este terminal.'},
    'Cash session not found': {'pt': 'Sessão de caixa não encontrada.', 'es': 'Sesión de caja no encontrada.'},
    'Terminal not found': {'pt': 'Caixa não encontrado.', 'es': 'Caja no encontrada.'},
    'Terminal not found or inactive': {'pt': 'Caixa não encontrado ou inativo.', 'es': 'Caja no encontrada o inactiva.'},
    'Terminal is operated by an installed device': {'pt': 'Este caixa é operado por um aplicativo instalado.', 'es': 'Esta caja la opera una aplicación instalada.'},
    'Item price changed; reload the price and try again': {'pt': 'O preço do item mudou. Atualize e tente de novo.', 'es': 'El precio del artículo cambió. Actualice e intente de nuevo.'},
    'Insufficient stock at the location': {'pt': 'Estoque insuficiente no local do caixa.', 'es': 'Stock insuficiente en el local de la caja.'},
    'Sale product not found or inactive': {'pt': 'Item não encontrado ou inativo.', 'es': 'Artículo no encontrado o inactivo.'},
    'Payment method is not accepted by the terminal': {'pt': 'Forma de pagamento não aceita neste caixa.', 'es': 'Forma de pago no aceptada en esta caja.'},
    'Payments minus change must equal the sale total': {'pt': 'Os pagamentos menos o troco devem fechar o total da venda.', 'es': 'Los pagos menos el cambio deben igualar el total de la venta.'},
    'Change must come from cash payments': {'pt': 'Só pagamento em dinheiro pode gerar troco.', 'es': 'Solo el pago en efectivo puede generar cambio.'},
    'Sale total must be greater than zero': {'pt': 'O total da venda deve ser maior que zero.', 'es': 'El total de la venta debe ser mayor que cero.'},
    'Cancel reason is required': {'pt': 'Informe o motivo do cancelamento.', 'es': 'Informe el motivo de la cancelación.'},
    'Cancel the fiscal document of the sale first': {'pt': 'Cancele primeiro o documento fiscal da venda.', 'es': 'Cancele primero el documento fiscal de la venta.'},
    'Only sales of an open cash session can be canceled at the POS': {'pt': 'Só vendas do caixa aberto podem ser canceladas no PDV.', 'es': 'Solo las ventas de la caja abierta se pueden cancelar en el TPV.'},
    'Sale not found': {'pt': 'Venda não encontrada.', 'es': 'Venta no encontrada.'},
    'Payment can no longer be confirmed': {'pt': 'O pagamento não pode mais ser confirmado.', 'es': 'El pago ya no se puede confirmar.'},
    'Pix needs a default payment gateway for this tenant. Use another payment method': {'pt': 'O Pix precisa de um gateway de pagamento configurado. Use outra forma de pagamento.', 'es': 'Pix necesita una pasarela de pago configurada. Use otra forma de pago.'},
    'No payment gateway configured. Register a default payment gateway for this tenant': {'pt': 'Nenhum gateway de pagamento configurado. Cadastre um gateway padrão para a empresa.', 'es': 'No hay pasarela de pago configurada. Registre una pasarela predeterminada para la empresa.'},
    'Invalid email or password': {'pt': 'E-mail ou senha inválidos.', 'es': 'Correo o contraseña inválidos.'},
    'Email and password are required': {'pt': 'Informe e-mail e senha.', 'es': 'Informe correo y contraseña.'},
    'No active billing subscription grants this entitlement': {'pt': 'O módulo PDV não está contratado para esta empresa.', 'es': 'El módulo TPV no está contratado para esta empresa.'},
    'Commercial billing policy is missing for this resource': {'pt': 'O módulo não está disponível para contratação. Fale com o suporte.', 'es': 'El módulo no está disponible para contratación. Contacte al soporte.'},
    'Unexpected database error': {'pt': 'Erro inesperado no servidor. Tente de novo.', 'es': 'Error inesperado del servidor. Intente de nuevo.'},
  };

  static const Map<String, Map<String, String>> _strings = {
    'app': {'pt': 'PDV', 'en': 'POS', 'es': 'TPV'},
    'deviceModeHint': {
      'pt': 'Este dispositivo vende mesmo sem internet: vendas e caixa ficam salvos aqui e são sincronizados.',
      'en': 'This device sells even without internet: sales and cash are stored here and synchronized.',
      'es': 'Este dispositivo vende incluso sin internet: ventas y caja se guardan aquí y se sincronizan.',
    },
    'deviceSynced': {'pt': 'Sincronizado', 'en': 'Synced', 'es': 'Sincronizado'},
    'devicePending': {'pt': 'a sincronizar', 'en': 'to sync', 'es': 'por sincronizar'},
    'deviceProblemsHint': {
      'pt': 'Operações recusadas ou com pendência no servidor: o gestor revisa em PDV › Sincronização.',
      'en': 'Operations refused or flagged by the server: the manager reviews them in POS › Sync.',
      'es': 'Operaciones rechazadas o con pendiente en el servidor: el gerente las revisa en TPV › Sincronización.',
    },
    'syncNow': {'pt': 'Sincronizar agora', 'en': 'Sync now', 'es': 'Sincronizar ahora'},
    'provisionTitle': {'pt': 'Operação offline', 'en': 'Offline operation', 'es': 'Operación offline'},
    'provisionHint': {
      'pt': 'Ativa este aparelho para vender sem internet neste caixa. O gestor define a autorização offline no MNSCloud.',
      'en': 'Enables this device to sell without internet on this register. The manager sets the offline authorization in MNSCloud.',
      'es': 'Habilita este equipo para vender sin internet en esta caja. El gerente define la autorización offline en MNSCloud.',
    },
    'deviceName': {'pt': 'Nome do aparelho', 'en': 'Device name', 'es': 'Nombre del equipo'},
    'provision': {'pt': 'Ativar neste aparelho', 'en': 'Enable on this device', 'es': 'Habilitar en este equipo'},
    'saleSavedOnDevice': {'pt': 'Venda salva neste aparelho', 'en': 'Sale saved on this device', 'es': 'Venta guardada en este equipo'},
    'waitingSync': {'pt': 'Aguardando sincronização', 'en': 'Waiting for sync', 'es': 'Esperando sincronización'},
    'nfceContingency': {'pt': 'NFC-e em contingência', 'en': 'NFC-e in contingency', 'es': 'NFC-e en contingencia'},
    'series': {'pt': 'Série', 'en': 'Series', 'es': 'Serie'},
    'signIn': {'pt': 'Entrar', 'en': 'Sign in', 'es': 'Ingresar'},
    'email': {'pt': 'E-mail', 'en': 'E-mail', 'es': 'Correo'},
    'password': {'pt': 'Senha', 'en': 'Password', 'es': 'Contraseña'},
    'chooseTenant': {'pt': 'Escolha a empresa', 'en': 'Choose the company', 'es': 'Elija la empresa'},
    'chooseTerminal': {'pt': 'Escolha o caixa', 'en': 'Choose the register', 'es': 'Elija la caja'},
    'noTerminals': {
      'pt': 'Nenhum caixa ativo. Cadastre um em PDV › Terminais no MNSCloud.',
      'en': 'No active register. Create one in POS › Terminals in MNSCloud.',
      'es': 'No hay cajas activas. Cree una en TPV › Terminales en MNSCloud.',
    },
    'openSession': {'pt': 'Abrir caixa', 'en': 'Open register', 'es': 'Abrir caja'},
    'openingAmount': {'pt': 'Fundo de troco', 'en': 'Opening cash', 'es': 'Fondo de caja'},
    'search': {'pt': 'Buscar item ou ler código', 'en': 'Search item or scan code', 'es': 'Buscar ítem o leer código'},
    'cart': {'pt': 'Venda', 'en': 'Sale', 'es': 'Venta'},
    'emptyCart': {'pt': 'Nenhum item na venda.', 'en': 'No items in the sale.', 'es': 'Ningún ítem en la venta.'},
    'subtotal': {'pt': 'Subtotal', 'en': 'Subtotal', 'es': 'Subtotal'},
    'discount': {'pt': 'Desconto', 'en': 'Discount', 'es': 'Descuento'},
    'total': {'pt': 'Total', 'en': 'Total', 'es': 'Total'},
    'paid': {'pt': 'Pago', 'en': 'Paid', 'es': 'Pagado'},
    'remaining': {'pt': 'Falta', 'en': 'Remaining', 'es': 'Falta'},
    'change': {'pt': 'Troco', 'en': 'Change', 'es': 'Vuelto'},
    'pay': {'pt': 'Pagamento', 'en': 'Payment', 'es': 'Pago'},
    'finish': {'pt': 'Finalizar venda', 'en': 'Finish sale', 'es': 'Finalizar venta'},
    'clear': {'pt': 'Limpar venda', 'en': 'Clear sale', 'es': 'Limpiar venta'},
    'cash': {'pt': 'Dinheiro', 'en': 'Cash', 'es': 'Efectivo'},
    'pix': {'pt': 'Pix', 'en': 'Pix', 'es': 'Pix'},
    'card_credit': {'pt': 'Cartão de crédito', 'en': 'Credit card', 'es': 'Tarjeta de crédito'},
    'card_debit': {'pt': 'Cartão de débito', 'en': 'Debit card', 'es': 'Tarjeta de débito'},
    'voucher': {'pt': 'Vale', 'en': 'Voucher', 'es': 'Vale'},
    'other': {'pt': 'Outro', 'en': 'Other', 'es': 'Otro'},
    'amount': {'pt': 'Valor', 'en': 'Amount', 'es': 'Valor'},
    'add': {'pt': 'Adicionar', 'en': 'Add', 'es': 'Agregar'},
    'cancel': {'pt': 'Cancelar', 'en': 'Cancel', 'es': 'Cancelar'},
    'confirm': {'pt': 'Confirmar', 'en': 'Confirm', 'es': 'Confirmar'},
    'close': {'pt': 'Fechar', 'en': 'Close', 'es': 'Cerrar'},
    'nsu': {'pt': 'NSU da maquininha', 'en': 'Terminal NSU', 'es': 'NSU del terminal'},
    'authCode': {'pt': 'Código de autorização', 'en': 'Authorization code', 'es': 'Código de autorización'},
    'cardHint': {
      'pt': 'Sem NSU o cartão fica pendente até a confirmação da maquininha.',
      'en': 'Without the NSU the card stays pending until the terminal confirms it.',
      'es': 'Sin NSU la tarjeta queda pendiente hasta que el terminal la confirme.',
    },
    'pixHint': {
      'pt': 'O Pix só é confirmado pelo banco, nunca por QR Code ou comprovante.',
      'en': 'Pix is confirmed only by the bank, never by the QR code or a receipt.',
      'es': 'El Pix lo confirma solo el banco, nunca el QR ni un comprobante.',
    },
    'saleSaved': {'pt': 'Venda registrada', 'en': 'Sale recorded', 'es': 'Venta registrada'},
    'saleNumber': {'pt': 'Venda nº', 'en': 'Sale no.', 'es': 'Venta n.º'},
    'paymentPending': {'pt': 'Pagamento pendente', 'en': 'Payment pending', 'es': 'Pago pendiente'},
    'paymentConfirmed': {'pt': 'Pagamento confirmado', 'en': 'Payment confirmed', 'es': 'Pago confirmado'},
    'generatePix': {'pt': 'Gerar Pix', 'en': 'Create Pix', 'es': 'Generar Pix'},
    'checkPix': {'pt': 'Verificar pagamento', 'en': 'Check payment', 'es': 'Verificar pago'},
    'copyPix': {'pt': 'Copiar código Pix', 'en': 'Copy Pix code', 'es': 'Copiar código Pix'},
    'noFiscal': {
      'pt': 'Comprovante não fiscal. O documento fiscal é emitido pelo módulo Fiscal quando configurado.',
      'en': 'Non-fiscal receipt. The fiscal document is issued by the Fiscal module when configured.',
      'es': 'Comprobante no fiscal. El documento fiscal lo emite el módulo Fiscal cuando está configurado.',
    },
    'register': {'pt': 'Caixa', 'en': 'Register', 'es': 'Caja'},
    'supply': {'pt': 'Suprimento', 'en': 'Cash in', 'es': 'Ingreso'},
    'withdrawal': {'pt': 'Sangria', 'en': 'Cash out', 'es': 'Retiro'},
    'closeSession': {'pt': 'Fechar caixa', 'en': 'Close register', 'es': 'Cerrar caja'},
    'countedCash': {'pt': 'Dinheiro contado', 'en': 'Counted cash', 'es': 'Efectivo contado'},
    'expectedCash': {'pt': 'Dinheiro esperado', 'en': 'Expected cash', 'es': 'Efectivo esperado'},
    'sales': {'pt': 'Vendas', 'en': 'Sales', 'es': 'Ventas'},
    'pendingPayments': {'pt': 'Pagamentos pendentes', 'en': 'Pending payments', 'es': 'Pagos pendientes'},
    'notes': {'pt': 'Observação', 'en': 'Notes', 'es': 'Observación'},
    'online': {'pt': 'Online', 'en': 'Online', 'es': 'En línea'},
    'unreachable': {'pt': 'Sem conexão com o servidor', 'en': 'Server unreachable', 'es': 'Sin conexión con el servidor'},
    'checking': {'pt': 'Verificando', 'en': 'Checking', 'es': 'Verificando'},
    'inDoubt': {
      'pt': 'Venda aguardando confirmação do servidor. Tente de novo: ela não será duplicada.',
      'en': 'Sale waiting for the server confirmation. Try again: it will not be duplicated.',
      'es': 'Venta esperando la confirmación del servidor. Reintente: no se duplicará.',
    },
    'retry': {'pt': 'Tentar novamente', 'en': 'Try again', 'es': 'Reintentar'},
    'checkSale': {'pt': 'Verificar venda', 'en': 'Check sale', 'es': 'Verificar venta'},
    'quantity': {'pt': 'Quantidade', 'en': 'Quantity', 'es': 'Cantidad'},
    'cancelSale': {'pt': 'Cancelar última venda', 'en': 'Cancel last sale', 'es': 'Cancelar última venta'},
    'reason': {'pt': 'Motivo', 'en': 'Reason', 'es': 'Motivo'},
    'webOnline': {
      'pt': 'Versão Web: funciona apenas online; nada é guardado no navegador.',
      'en': 'Web version: online only; nothing is stored in the browser.',
      'es': 'Versión Web: solo en línea; nada se guarda en el navegador.',
    },
    'switchTerminal': {'pt': 'Trocar caixa', 'en': 'Change register', 'es': 'Cambiar caja'},
    'signOut': {'pt': 'Sair', 'en': 'Sign out', 'es': 'Salir'},
    'stock': {'pt': 'Estoque', 'en': 'Stock', 'es': 'Stock'},
    'scanWithCamera': {'pt': 'Ler código com a câmera', 'en': 'Scan with the camera', 'es': 'Leer código con la cámara'},
    'cameraUnavailable': {
      'pt': 'Câmera indisponível. Permita o acesso à câmera ou use o leitor de código de barras.',
      'en': 'Camera unavailable. Allow camera access or use the barcode reader.',
      'es': 'Cámara no disponible. Permita el acceso a la cámara o use el lector de códigos.',
    },
    'invalidAmount': {'pt': 'Valor inválido. Use o formato 1.234,56.', 'en': 'Invalid amount. Use the format 1,234.56.', 'es': 'Monto inválido. Use el formato 1.234,56.'},
    'discountMax': {'pt': 'Desconto máximo deste item', 'en': 'Maximum discount for this item', 'es': 'Descuento máximo de este artículo'},
    'supplies': {'pt': 'Suprimentos', 'en': 'Cash in', 'es': 'Ingresos'},
    'withdrawals': {'pt': 'Sangrias', 'en': 'Cash out', 'es': 'Retiros'},
    'cashSalesNet': {'pt': 'Dinheiro das vendas (líquido de troco)', 'en': 'Cash from sales (net of change)', 'es': 'Efectivo de ventas (neto de cambio)'},
    'movementSaved': {'pt': 'Movimento registrado.', 'en': 'Movement saved.', 'es': 'Movimiento registrado.'},
    'sessionSales': {'pt': 'Vendas deste caixa', 'en': 'Sales of this register', 'es': 'Ventas de esta caja'},
    'noSessionSales': {'pt': 'Nenhuma venda neste caixa.', 'en': 'No sales in this register.', 'es': 'Ninguna venta en esta caja.'},
    'canceled': {'pt': 'Cancelada', 'en': 'Canceled', 'es': 'Cancelada'},
    'cancelThisSale': {'pt': 'Cancelar venda', 'en': 'Cancel sale', 'es': 'Cancelar venta'},
    'cancelReasonRequired': {'pt': 'Informe o motivo do cancelamento.', 'en': 'Enter the cancel reason.', 'es': 'Informe el motivo de la cancelación.'},
    'sessionClosed': {'pt': 'Caixa fechado', 'en': 'Register closed', 'es': 'Caja cerrada'},
    'difference': {'pt': 'Diferença', 'en': 'Difference', 'es': 'Diferencia'},
    'pixUnavailable': {
      'pt': 'Pix indisponível: a empresa não tem gateway de pagamento configurado.',
      'en': 'Pix unavailable: the company has no payment gateway configured.',
      'es': 'Pix no disponible: la empresa no tiene pasarela de pago configurada.',
    },
    'signOutQuestion': {'pt': 'Sair do PDV?', 'en': 'Sign out of the POS?', 'es': '¿Salir del TPV?'},
    'signOutHint': {
      'pt': 'Sua sessão será encerrada neste dispositivo. Para voltar, entre de novo com e-mail e senha.',
      'en': 'Your session ends on this device. Sign in again with e-mail and password to come back.',
      'es': 'Su sesión se cerrará en este dispositivo. Para volver, ingrese de nuevo con correo y contraseña.',
    },
    'signOutCart': {
      'pt': 'A venda em andamento será descartada.',
      'en': 'The sale in progress will be discarded.',
      'es': 'La venta en curso se descartará.',
    },
    'signOutCashOpen': {
      'pt': 'O caixa continua aberto para o próximo operador. Se o turno terminou, feche o caixa antes de sair.',
      'en': 'The register stays open for the next operator. If your shift is over, close the register before signing out.',
      'es': 'La caja sigue abierta para el próximo operador. Si terminó su turno, cierre la caja antes de salir.',
    },
    'signOutInDoubt': {
      'pt': 'Uma venda ainda está sendo confirmada. Aguarde a confirmação antes de sair.',
      'en': 'A sale is still being confirmed. Wait for it before signing out.',
      'es': 'Una venta aún se está confirmando. Espere la confirmación antes de salir.',
    },
  };
}
