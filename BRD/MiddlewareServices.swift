//
//  MiddlewareServices.swift
//  LinphoneApp
//
//  Created by Davi  on 19/11/25.
//

import Foundation

#if USE_CRASHLYTICS
import FirebaseMessaging
#endif

class MiddlewareServices {
    
    // MARK: - Configuration
    // Configure a URL da sua API aqui
    private static let middlewareBaseURL = "http://168.121.7.18:3000"
    private static let tokenEndpoint = "/user/upsert"
    private static let unregisterEndpoint = "/user/deleteToken"
    
    // MARK: - Public Methods
    
    /// Envia o token VoIP (APNs) para o middleware
    public static func registerAPNSToken(userID_Domain: String, voipToken: String) async {
        Log.info("BRD_APNS: Registrando token VoIP na API")
        
        // Constrói a URL completa
        guard let url = URL(string: middlewareBaseURL + tokenEndpoint) else {
            Log.error("BRD_SERVER: URL inválida: \(middlewareBaseURL + tokenEndpoint)")
            return
        }
        
        await sendTokenToMiddleware(url: url, userID_Domain: userID_Domain, token: voipToken)
    }
    
    /// Remove o registro do token VoIP (APNs) do middleware (usado no logout)
    public static func unregisterAPNSToken(userID_Domain: String) async {
        Log.info("BRD_APNS: Removendo registro de token VoIP da API")
        
        // Obtém o token armazenado localmente
        guard let token = UserDefaults.standard.string(forKey: "lastSentAPNSToken") else {
            Log.warn("BRD_APNS: Nenhum token APNS encontrado para desregistrar")
            return
        }
        
        // Constrói a URL completa
        guard let url = URL(string: middlewareBaseURL + unregisterEndpoint) else {
            Log.error("BRD_SERVER: URL inválida: \(middlewareBaseURL + unregisterEndpoint)")
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10.0
        
        let jsonParams: [String: Any] = [
            "userID_Domain": userID_Domain,
            "token": token
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonParams)
            
            if let jsonString = String(data: request.httpBody!, encoding: .utf8) {
                Log.info("BRD_SERVER: Payload JSON (unregister): \(jsonString)")
            }
            
            // Envia a requisição
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                Log.error("BRD_SERVER: Resposta inválida do servidor (unregister)")
                return
            }
            
            let responseBody = String(data: data, encoding: .utf8) ?? "N/A"
            Log.info("BRD_SERVER: Status HTTP (unregister): \(httpResponse.statusCode)")
            Log.info("BRD_SERVER: Resposta do servidor (unregister): \(responseBody)")
            
            if (200...299).contains(httpResponse.statusCode) {
                Log.info("BRD_SERVER: Token VoIP/APNS removido com sucesso da API!")
                
                // Remove informações locais do token
                UserDefaults.standard.removeObject(forKey: "lastSentAPNSToken")
                UserDefaults.standard.removeObject(forKey: "lastAPNSTokenSentDate")
                Log.info("BRD_SERVER: Token VoIP removido do cache local")
            } else {
                Log.error("BRD_SERVER: Erro ao remover token (Status: \(httpResponse.statusCode))")
                Log.error("BRD_SERVER: Corpo da resposta: \(responseBody)")
            }
            
        } catch {
            Log.error("BRD_SERVER: Exceção ao remover token: \(error.localizedDescription)")
            Log.error("BRD_SERVER: Tipo de erro: \(type(of: error))")
        }
    }
    
    /// Mantém método antigo para compatibilidade (deprecated)
    @available(*, deprecated, message: "Use registerAPNSToken com token VoIP")
    public static func registerFCMToken(userID_Domain: String) async {
        #if USE_CRASHLYTICS
        guard let fcmToken = await getFCMToken() else {
            Log.error("BRD_FCM: Não foi possível obter o token FCM")
            return
        }
        
        Log.info("BRD_FCM: Token FCM obtido com sucesso")
        
        // Constrói a URL completa
        guard let url = URL(string: middlewareBaseURL + tokenEndpoint) else {
            Log.error("BRD_SERVER: URL inválida: \(middlewareBaseURL + tokenEndpoint)")
            return
        }
        
        await sendTokenToMiddleware(url: url, userID_Domain: userID_Domain, token: fcmToken)
        #else
        Log.warn("BRD_FCM: Firebase não está habilitado. USE_CRASHLYTICS não está definido.")
        #endif
    }
    
    /// Envia o token para o middleware
    public static func sendTokenToMiddleware(url: URL, userID_Domain: String, token: String) async {
        Log.info("=== BRD_SERVER: ENVIANDO TOKEN APNS/VOIP PARA MIDDLEWARE ===")
        Log.info("BRD_SERVER: URL: \(url.absoluteString)")
        Log.info("BRD_SERVER: User: \(userID_Domain)")
        Log.info("BRD_SERVER: Token VoIP (primeiros 30): \(String(token.prefix(30)))...")
        Log.info("BRD_SERVER: Token VoIP (completo): \(token)")
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10.0
        
        let jsonParams: [String: Any] = [
            "userID_Domain": userID_Domain,
            "token": token,
            "platform": "IOS"
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonParams)
            
            if let jsonString = String(data: request.httpBody!, encoding: .utf8) {
                Log.info("BRD_SERVER: Payload JSON: \(jsonString)")
            }
            
            // Envia a requisição
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                Log.error("BRD_SERVER: Resposta inválida do servidor")
                return
            }
            
            let responseBody = String(data: data, encoding: .utf8) ?? "N/A"
            Log.info("BRD_SERVER: Status HTTP: \(httpResponse.statusCode)")
            Log.info("BRD_SERVER: Resposta do servidor: \(responseBody)")
            
            if (200...299).contains(httpResponse.statusCode) {
                Log.info("BRD_SERVER: Token VoIP/APNS registrado com sucesso na API!")
                
                // Salva a informação de que o token foi enviado
                UserDefaults.standard.set(token, forKey: "lastSentAPNSToken")
                UserDefaults.standard.set(Date(), forKey: "lastAPNSTokenSentDate")
                Log.info("BRD_SERVER: Token VoIP salvo em cache local")
            } else {
                Log.error("BRD_SERVER: Erro ao enviar token (Status: \(httpResponse.statusCode))")
                Log.error("BRD_SERVER: Corpo da resposta: \(responseBody)")
            }
            
        } catch {
            Log.error("BRD_SERVER:   Exceção ao enviar token: \(error.localizedDescription)")
            Log.error("BRD_SERVER: Tipo de erro: \(type(of: error))")
        }
        
        Log.info("=== BRD_SERVER: FIM DO ENVIO ===")
    }
    
    // MARK: - Private Methods
    
    /// Obtém o token FCM do Firebase Messaging
    private static func getFCMToken() async -> String? {
        #if USE_CRASHLYTICS
        return await withCheckedContinuation { continuation in
            Messaging.messaging().token { token, error in
                if let error = error {
                    Log.error("BRD_FCM: Erro ao obter token: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                } else if let token = token {
                    Log.info("BRD_FCM: Token FCM recebido do Firebase")
                    continuation.resume(returning: token)
                } else {
                    Log.error("BRD_FCM: Token é nil sem erro")
                    continuation.resume(returning: nil)
                }
            }
        }
        #else
        return nil
        #endif
    }
    
    /// Verifica se o token precisa ser reenviado
    public static func shouldUpdateToken(currentToken: String) -> Bool {
        guard let lastToken = UserDefaults.standard.string(forKey: "lastSentAPNSToken"),
              let lastSentDate = UserDefaults.standard.object(forKey: "lastAPNSTokenSentDate") as? Date else {
            return true // Nunca foi enviado
        }
        
        // Reenvia se o token mudou ou se passou mais de 30 dias
        let daysSinceLastSent = Calendar.current.dateComponents([.day], from: lastSentDate, to: Date()).day ?? 0
        return currentToken != lastToken || daysSinceLastSent > 30
    }
    
    /// Sincroniza o token FCM com o middleware (chamado quando o app volta do background)
    public static func syncFCMTokenIfNeeded() async {
        #if USE_CRASHLYTICS
        guard let fcmToken = await getFCMToken() else {
            Log.warn("BRD_FCM: Não foi possível obter token para sincronização")
            return
        }
        
        // Verifica se precisa atualizar
        guard shouldUpdateToken(currentToken: fcmToken) else {
            Log.info("BRD_FCM: Token já está atualizado, não é necessário reenviar")
            return
        }
        
        Log.info("BRD_FCM: Token mudou ou expirou, reenviando...")
        
        // Obtém o userID_Domain da conta atual
        if let coreContext = CoreContext.shared as CoreContext?,
           let account = coreContext.mCore?.defaultAccount ?? coreContext.mCore?.accountList.first,
           let identity = account.params?.identityAddress?.asStringUriOnly() {
            
            guard let url = URL(string: middlewareBaseURL + tokenEndpoint) else {
                Log.error("BRD_SERVER: URL inválida")
                return
            }
            
            await sendTokenToMiddleware(url: url, userID_Domain: identity, token: fcmToken)
        } else {
            Log.warn("BRD_FCM: Nenhuma conta disponível para sincronizar token")
        }
        #endif
    }
}
