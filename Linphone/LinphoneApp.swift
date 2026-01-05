/*
 * Copyright (c) 2010-2023 Belledonne Communications SARL.
 *
 * This file is part of linphone-iphone
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */

import SwiftUI
import linphonesw
import UserNotifications
import PushKit
import CallKit

#if USE_CRASHLYTICS
import Firebase
import FirebaseMessaging
#endif

let accountTokenNotification = Notification.Name("AccountCreationTokenReceived")
var displayedChatroomPeerAddr: String?

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, PKPushRegistryDelegate {
	
	var launchNotificationCallId: String?
	var launchNotificationPeerAddr: String?
	var launchNotificationLocalAddr: String?
	
	var coreContext: CoreContext?
 	var navigationManager: NavigationManager?
	
	// PushKit registry para VoIP
	private var pushRegistry: PKPushRegistry?
	
	func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
		let tokenStr = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
		Log.info("=== BRD_APNS: TOKEN RECEBIDO ===")
		Log.info("BRD_APNS: Token APNS (hex): \(tokenStr)")
		Log.info("BRD_APNS: Token length: \(tokenStr.count) caracteres")
		
		// Salva para referência
		UserDefaults.standard.set(tokenStr, forKey: "lastAPNSToken")
		UserDefaults.standard.set(Date(), forKey: "lastAPNSTokenDate")
		
		// Firebase usa este token APNS para gerar token FCM
		// Fluxo: APNS token → Firebase (gera FCM token) → API → PBX notifica → API → Firebase → APNS → App
		// Firebase faz intermediação: JWT + HTTP/2 para APNS (iOS) ou FCM direto (Android)
		Log.info("BRD_APNS: Firebase usará este token para gerar FCM token e intermediar push via APNS")
		Log.info("=== BRD_APNS: REGISTRO COMPLETO ===")
	}
	
	func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
		Log.error("Failed to register for push notifications : \(error.localizedDescription)")
	}
	
	func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
		Log.info("=== BRD_PUSH: PUSH RECEBIDA ===")
		Log.info("BRD_PUSH: App state: \(application.applicationState.rawValue)") // 0=active, 1=inactive, 2=background
		Log.info("BRD_PUSH: Payload = \(userInfo)")
		
		// Push silenciosa apenas acorda o app
		// Linphone SDK já está configurado para receber a chamada SIP normalmente
		
		if let callType = userInfo["type"] as? String, callType == "call" {
			Log.info("BRD_PUSH: Silent push recebida - app acordado")
			Log.info("BRD_PUSH: Aguardando INVITE SIP...")
			completionHandler(.newData)
		} else {
			// Outras notificações (ex: token de criação de conta)
			let creationToken = (userInfo["customPayload"] as? NSDictionary)?["token"] as? String
			if let creationToken = creationToken {
				NotificationCenter.default.post(name: accountTokenNotification, object: nil, userInfo: ["token": creationToken])
			}
			completionHandler(.newData)
		}
	}
	
	func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
		// Configure Firebase
		#if USE_CRASHLYTICS
		FirebaseApp.configure()
		
		// Configure Firebase Messaging
		Messaging.messaging().delegate = self
		#endif
		
		// Set up notifications
		UNUserNotificationCenter.current().delegate = self
		
		// IMPORTANTE: Configurar PushKit para VoIP (obrigatório para chamadas)
		setupPushKit()
		
		// Verifica estado atual de push notifications
		checkPushNotificationStatus(application: application)
		
		// Request notification authorization (para notificações visuais opcionais)
		UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
			if granted {
				Log.info("BRD_PUSH: Permissão de notificação concedida")
			} else if let error = error {
				Log.error("BRD_PUSH: Erro ao solicitar permissão: \(error.localizedDescription)")
			}
		}
		
		return true
	}
	
	// MARK: - PushKit Setup (OBRIGATÓRIO para VoIP)
	private func setupPushKit() {
		Log.info("=== BRD_PUSHKIT: CONFIGURANDO VOIP ===")
		pushRegistry = PKPushRegistry(queue: DispatchQueue.main)
		pushRegistry?.delegate = self
		pushRegistry?.desiredPushTypes = [.voIP]
		Log.info("BRD_PUSHKIT: PushKit configurado - aguardando token VoIP")
	}
	
	// MARK: - PKPushRegistryDelegate
	
	/// Chamado quando o token VoIP é recebido
	func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
		guard type == .voIP else { return }
		
		let tokenParts = pushCredentials.token.map { String(format: "%02.2hhx", $0) }
		let token = tokenParts.joined()
		
        Log.info("=== BRD_PUSHKIT: TOKEN VOIP RECEBIDO ===")
		Log.info("BRD_PUSHKIT: Token VoIP: \(token)")
		Log.info("BRD_PUSHKIT: Token length: \(token.count) caracteres")
		
		// Salva token VoIP
		UserDefaults.standard.set(token, forKey: "lastVoIPToken")
		UserDefaults.standard.set(Date(), forKey: "lastVoIPTokenDate")
		
		// CRUCIAL: Envia token VoIP para Firebase gerar FCM token
		#if USE_CRASHLYTICS
		Messaging.messaging().apnsToken = pushCredentials.token
		Log.info("BRD_PUSHKIT: ✓ Token VoIP enviado ao Firebase para gerar FCM token")
		#endif
		
		// NOVO: Envia token VoIP diretamente para API (APNs direto)
		Log.info("BRD_PUSHKIT: 📤 Enviando token VoIP para API middleware...")
		Task {
			if let coreContext = coreContext as CoreContext?,
			   let account = coreContext.mCore?.defaultAccount ?? coreContext.mCore?.accountList.first,
			   let identity = account.params?.identityAddress?.asStringUriOnly() {
				await MiddlewareServices.registerAPNSToken(userID_Domain: identity, voipToken: token)
				Log.info("BRD_PUSHKIT: Token VoIP enviado para API")
			} else {
				Log.warn("BRD_PUSHKIT: Conta ainda não disponível, token VoIP será enviado quando conta estiver pronta")
				// Salva token para enviar depois
				UserDefaults.standard.set(token, forKey: "pendingVoIPToken")
			}
		}
		
		Log.info("=== BRD_PUSHKIT: REGISTRO VOIP COMPLETO ===")
	}
	
	/// Chamado quando recebe push VoIP (app fechado/background)
	/// CRÍTICO: Apple EXIGE reportar chamada ao CallKit dentro de 3 segundos ou app é morto
	func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
		guard type == .voIP else {
			completion()
			return
		}
		
		Log.info("=== BRD_PUSHKIT: PUSH VOIP RECEBIDA (TELA BLOQUEADA/APAGADA) ===")
		Log.info("BRD_PUSHKIT: Payload VoIP = \(payload.dictionaryPayload)")
		
		// Extrai informações da chamada do payload
		// Aceita tanto formato antigo (from/display-name) quanto novo (caller_id/display_name)
		let fromUser = payload.dictionaryPayload["caller_id"] as? String 
			?? payload.dictionaryPayload["from"] as? String 
			?? "sip:unknown@unknown"
		let displayName = payload.dictionaryPayload["display_name"] as? String 
			?? payload.dictionaryPayload["display-name"] as? String 
			?? "Chamada recebida"
		let callId = payload.dictionaryPayload["call_id"] as? String 
			?? payload.dictionaryPayload["call-id"] as? String 
			?? UUID().uuidString
		
		Log.info("BRD_PUSHKIT: Push VoIP recebido - processando chamada")
		Log.info("BRD_PUSHKIT: De: \(fromUser)")
		Log.info("BRD_PUSHKIT: Nome: \(displayName)")
		Log.info("BRD_PUSHKIT: Call-ID: \(callId)")
		
		// CRÍTICO: Chama completion() IMEDIATAMENTE (Apple exige < 3 segundos)
		// O resto do processamento continua assíncrono
		completion()
		Log.info("BRD_PUSHKIT: completion() chamado - Apple satisfeita")
		
		// PASSO 1: ACORDAR LINPHONE CORE (primeiro, antes de CallKit)
		if let coreContext = coreContext {
			Log.info("BRD_PUSHKIT: Acordando Linphone core...")
			
			coreContext.doOnCoreQueue { core in
				// Garante que o core está rodando
				if core.globalState == .Off || core.globalState == .Shutdown {
					Log.info("BRD_PUSHKIT: Core estava desligado, iniciando...")
					do {
						try core.start()
						Log.info("BRD_PUSHKIT: ✓ Core iniciado com sucesso")
					} catch {
						Log.error("BRD_PUSHKIT:   Erro ao iniciar core: \(error)")
					}
				} else {
					Log.info("BRD_PUSHKIT: ✓ Core já está rodando (estado: \(core.globalState))")
				}
				
				// Força refresh do registro SIP
				if let account = core.defaultAccount {
					Log.info("BRD_PUSHKIT: Forçando refresh do registro SIP...")
					do {
						try account.refreshRegister()
						Log.info("BRD_PUSHKIT: ✓ Registro SIP atualizado")
					} catch {
						Log.error("BRD_PUSHKIT:   Erro no refresh SIP: \(error)")
					}
				}
			}
		} else {
			Log.error("BRD_PUSHKIT:   CoreContext não disponível!")
		}
		
		// PASSO 2: REPORTAR CHAMADA AO CALLKIT (OBRIGATÓRIO!)
		// Apple MATA o app se não reportar em ~3 segundos
		Log.info("BRD_PUSHKIT: 🚨 Reportando chamada ao CallKit (OBRIGATÓRIO para tela bloqueada)")
		
		let uuid = UUID()
		let update = CXCallUpdate()
		update.remoteHandle = CXHandle(type: .generic, value: fromUser)
		update.hasVideo = false
		update.localizedCallerName = displayName
		
		// Usa o TelecomManager existente do app
		if TelecomManager.callKitEnabled() {
			let providerDelegate = TelecomManager.shared.providerDelegate
			
			// Cria CallInfo para rastrear
			let callInfo = CallInfo.newIncomingCallInfo(callId: callId)
			providerDelegate.callInfos[uuid] = callInfo
			providerDelegate.uuids[callId] = uuid
			
			Log.info("BRD_PUSHKIT: CallKit habilitado - reportando chamada com UUID: \(uuid)")
			
			// Reporta ao CallKit (isso mostra a tela de chamada nativa do iOS)
			providerDelegate.provider.reportNewIncomingCall(with: uuid, update: update) { error in
				if let error = error {
					Log.error("BRD_PUSHKIT:   Erro ao reportar chamada ao CallKit: \(error.localizedDescription)")
					Log.error("BRD_PUSHKIT: Código do erro: \((error as NSError).code)")
				} else {
					Log.info("BRD_PUSHKIT: SUCESSO - Chamada reportada ao CallKit!")
					Log.info("BRD_PUSHKIT: Tela de chamada nativa do iOS deve aparecer agora")
				}
			}
		} else {
			Log.error("BRD_PUSHKIT: CallKit DESABILITADO - chamadas com tela bloqueada NÃO FUNCIONARÃO!")
			Log.error("BRD_PUSHKIT: Habilite CallKit nas configurações do app")
		}
		
		Log.info("BRD_PUSHKIT: App pronto - aguardando INVITE SIP do servidor...")
		Log.info("=== BRD_PUSHKIT: PROCESSAMENTO CONCLUÍDO ===")
	}
	
	/// Chamado se o token VoIP for invalidado
	func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
		Log.warn("BRD_PUSHKIT: Token VoIP foi invalidado")
		UserDefaults.standard.removeObject(forKey: "lastVoIPToken")
	}
	
	// MARK: - Push Notification Diagnostics
	private func checkPushNotificationStatus(application: UIApplication) {
		Log.info("=== BRD_PUSH: DIAGNÓSTICO ===")
		
		// Verifica token VoIP (PushKit) - PRINCIPAL para VoIP
		if let voipToken = UserDefaults.standard.string(forKey: "lastVoIPToken"),
		   let voipDate = UserDefaults.standard.object(forKey: "lastVoIPTokenDate") as? Date {
			Log.info("BRD_PUSH: Token VoIP (PushKit): \(voipToken)")
			Log.info("BRD_PUSH: VoIP recebido em: \(voipDate)")
		} else {
			Log.warn("BRD_PUSH:   Token VoIP ainda não foi recebido")
		}
		
		// Verifica token FCM
		if let fcmToken = UserDefaults.standard.string(forKey: "currentFCMToken") {
			Log.info("BRD_PUSH: Token FCM: \(fcmToken)")
		} else {
			Log.warn("BRD_PUSH: Token FCM ainda não foi gerado")
		}
		
		// Verifica Background Modes
		if let backgroundModes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] {
			Log.info("BRD_PUSH: Background Modes: \(backgroundModes.joined(separator: ", "))")
			if backgroundModes.contains("voip") {
				Log.info("BRD_PUSH: VoIP background mode habilitado")
			} else {
				Log.error("BRD_PUSH:   VoIP background mode NÃO habilitado!")
			}
		}
		
		Log.info("=== BRD_PUSH: FIM DIAGNÓSTICO ===")
	}
	
	// Called when the user interacts with the notification
	func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
		let userInfo = response.notification.request.content.userInfo
		
		if let callId = userInfo["CallId"] as? String, let peerAddr = userInfo["peer_addr"] as? String, let localAddr = userInfo["local_addr"] as? String {
			if self.navigationManager != nil {
				self.navigationManager!.selectedCallId = callId
				self.navigationManager!.peerAddr = peerAddr
				self.navigationManager!.localAddr = localAddr
			} else {
				launchNotificationCallId = callId
				launchNotificationPeerAddr = peerAddr
				launchNotificationLocalAddr = localAddr
			}
		}
		
		completionHandler()
	}
	
	// Display notifications on foreground
	func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
		let userInfo = notification.request.content.userInfo
		Log.info("Received push notification in foreground, payload= \(userInfo)")
		
		let strPeerAddr = userInfo["peer_addr"] as? String
		if strPeerAddr == nil {
			// Não é uma chamada, exibe normalmente
			completionHandler([.banner, .sound])
		} else {
			// É uma chamada - verifica se deve exibir
			if displayedChatroomPeerAddr != strPeerAddr {
				if let coreContext = coreContext {
					coreContext.doOnCoreQueue { core in
						let nilParams: ConferenceParams? = nil
						if let peerAddr = try? Factory.Instance.createAddress(addr: strPeerAddr!),
						   let chatroom = core.searchChatRoom(params: nilParams, localAddr: nil, remoteAddr: peerAddr, participants: nil),
						   chatroom.muted {
							Log.info("message comes from a muted chatroom, ignore it")
							completionHandler([])
						} else {
							// Exibe a notificação da chamada
							completionHandler([.banner, .sound])
						}
					}
				} else {
					// Se não há coreContext, exibe a notificação
					completionHandler([.banner, .sound])
				}
			} else {
				// Já está no chatroom, não exibe
				completionHandler([])
			}
		}
	}
	
	func applicationWillTerminate(_ application: UIApplication) {
		Log.info("IOS applicationWillTerminate")
		if let coreContext = coreContext {
			coreContext.doOnCoreQueue(synchronous: true) { core in
				Log.info("applicationWillTerminate - Stopping linphone core")
				MagicSearchSingleton.shared.destroyMagicSearch()
				if core.globalState != GlobalState.Off {
					core.stop()
				} else {
					Log.info("applicationWillTerminate - Core already stopped")
				}
			}
		}
	}
}

@main
struct LinphoneApp: App {
	@Environment(\.scenePhase) var scenePhase
	@UIApplicationDelegateAdaptor(AppDelegate.self) var delegate

	@StateObject private var coreContext = CoreContext.shared
	@StateObject private var navigationManager = NavigationManager()
	@StateObject private var telecomManager = TelecomManager.shared
	@StateObject private var sharedMainViewModel = SharedMainViewModel.shared

	var body: some Scene {
		WindowGroup {
			RootView(
				coreContext: coreContext,
				telecomManager: telecomManager,
				sharedMainViewModel: sharedMainViewModel,
				navigationManager: navigationManager,
				appDelegate: delegate
			)
			.environmentObject(coreContext)
			.environmentObject(navigationManager)
			.environmentObject(telecomManager)
			.environmentObject(sharedMainViewModel)
		}
		.onChange(of: scenePhase) { newPhase in
			if !telecomManager.callInProgress {
				switch newPhase {
				case .active:
					Log.info("Entering foreground")
					coreContext.onEnterForeground()
				case .background:
					Log.info("Entering background")
					coreContext.onEnterBackground()
				default:
					break
				}
			}
		}
	}
}

struct RootView: View {
	@ObservedObject var coreContext: CoreContext
	@ObservedObject var telecomManager: TelecomManager
	@ObservedObject var sharedMainViewModel: SharedMainViewModel
	@ObservedObject var navigationManager: NavigationManager
	@State private var pendingURL: URL?
	let appDelegate: AppDelegate

	var body: some View {
		Group {
			if coreContext.coreHasStartedOnce {
				if showWelcome {
					ZStack {
						WelcomeView()
						ToastView().zIndex(3)
					}
					.onAppear {
						appDelegate.coreContext = coreContext
					}
				} else if showAssistant {
					ZStack {
						AssistantView()
						ToastView().zIndex(3)
					}
					.onAppear {
						appDelegate.coreContext = coreContext
					}
					
					if coreContext.coreIsStarted {
						   VStack {} // Force trigger .onAppear
							   .onAppear {
								   if let url = pendingURL {
									   URIHandler.handleURL(url: url)
									   pendingURL = nil
								   }
							   }
					   }
				} else {
					ZStack {
						MainViewSwitcher(
							coreContext: coreContext,
							navigationManager: navigationManager,
							sharedMainViewModel: sharedMainViewModel,
							pendingURL: $pendingURL,
							appDelegate: appDelegate
						)
						
						if coreContext.coreIsStarted {
							VStack {} // Force trigger .onAppear
								.onAppear {
									if let url = pendingURL {
										URIHandler.handleURL(url: url)
										pendingURL = nil
									}
								}
						}
					}
				}
			} else {
				SplashScreen()
			}
		}
		.onOpenURL { url in
			if SharedMainViewModel.shared.displayedConversation != nil && url.absoluteString.contains("linphone-message://") {
				SharedMainViewModel.shared.displayedConversation = nil
			}
			if coreContext.coreIsStarted {
				URIHandler.handleURL(url: url)
			} else {
				pendingURL = url
			}
		}
	}
	
	
	var showWelcome: Bool {
		!sharedMainViewModel.welcomeViewDisplayed
	}

	var showAssistant: Bool {
		(coreContext.coreIsStarted && coreContext.accounts.isEmpty)
		|| sharedMainViewModel.displayProfileMode
	}
}

struct MainViewSwitcher: View {
	let coreContext: CoreContext
	let navigationManager: NavigationManager
	let sharedMainViewModel: SharedMainViewModel
	@Binding var pendingURL: URL?
	let appDelegate: AppDelegate
	@ObservedObject private var colors = ColorProvider.shared

	var body: some View {
		selectedMainView()
	}
	
	@ViewBuilder
	func selectedMainView() -> some View {
		ContentView()
			.onAppear {
				appDelegate.coreContext = coreContext
				appDelegate.navigationManager = navigationManager
				
				if let callId = appDelegate.launchNotificationCallId,
				   let peerAddr = appDelegate.launchNotificationPeerAddr,
				   let localAddr = appDelegate.launchNotificationLocalAddr {
					navigationManager.openChatRoom(callId: callId, peerAddr: peerAddr, localAddr: localAddr)
				}
			}
			.id(colors.theme.name)
	}
}

// MARK: - Firebase Messaging Delegate
#if USE_CRASHLYTICS
extension AppDelegate: MessagingDelegate {
	
	/// Chamado quando o token FCM é atualizado
	func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
		guard let fcmToken = fcmToken else {
			Log.error("BRD_FCM: Token FCM é nil")
			return
		}
		
		Log.info("=== BRD_FCM: TOKEN FCM RECEBIDO ===")
		Log.info("BRD_FCM: Token completo: \(fcmToken)")
		Log.info("BRD_FCM: Token length: \(fcmToken.count) caracteres")
		Log.info("BRD_FCM: Primeiros 30 caracteres: \(String(fcmToken.prefix(30)))...")
		
		// Salva o token localmente
		UserDefaults.standard.set(fcmToken, forKey: "currentFCMToken")
		UserDefaults.standard.set(Date(), forKey: "currentFCMTokenDate")
		Log.info("BRD_FCM: ✓ Token FCM salvo localmente")
		
		// Envia o token para o middleware quando houver uma conta logada
		Task {
			// Aguarda um pouco para garantir que o coreContext está disponível
			try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 segundo
			
			if let coreContext = self.coreContext {
				coreContext.doOnCoreQueue { core in
					// Obtém o primeiro account ativo
					if let account = core.defaultAccount ?? core.accountList.first,
					   let identity = account.params?.identityAddress?.asStringUriOnly() {
						
						Log.info("BRD_FCM: Conta encontrada: \(identity)")
						
						// Verifica se há token VoIP pendente para enviar
						if let pendingVoIPToken = UserDefaults.standard.string(forKey: "pendingVoIPToken") {
							Log.info("BRD_FCM: Token VoIP pendente encontrado, enviando para API...")
							Task {
								await MiddlewareServices.registerAPNSToken(userID_Domain: identity, voipToken: pendingVoIPToken)
								// Remove token pendente após envio
								UserDefaults.standard.removeObject(forKey: "pendingVoIPToken")
								Log.info("BRD_FCM: Token VoIP pendente enviado com sucesso")
							}
						} else if let currentVoIPToken = UserDefaults.standard.string(forKey: "lastVoIPToken") {
							// Se não há pendente, verifica se precisa reenviar o atual
							Log.info("BRD_FCM: Verificando se token VoIP atual precisa ser reenviado...")
							Task {
								if MiddlewareServices.shouldUpdateToken(currentToken: currentVoIPToken) {
									Log.info("BRD_FCM: Token VoIP precisa ser atualizado, enviando...")
									await MiddlewareServices.registerAPNSToken(userID_Domain: identity, voipToken: currentVoIPToken)
								} else {
									Log.info("BRD_FCM: Token VoIP já está atualizado")
								}
							}
						} else {
							Log.warn("BRD_FCM: Nenhum token VoIP disponível ainda")
						}
					} else {
						Log.warn("BRD_FCM: Nenhuma conta disponível. Token será enviado após login.")
						Log.warn("BRD_FCM: Accounts disponíveis: \(core.accountList.count)")
					}
				}
			} else {
				Log.error("BRD_FCM: CoreContext não disponível!")
			}
		}
	}
}
#endif
