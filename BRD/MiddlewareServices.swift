//
//  MiddlewareServices.swift
//  LinphoneApp
//
//  Created by Davi  on 19/11/25.
//

import Foundation

class MiddlewareServices {
    
    public static func sendTokenToMiddleware(url: URL, userID_Domain: String, token: String) async {
        print("BRD_SERVER_func: Entry")
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5.0
        
        let jsonParams: [String: Any] = [
            "userID_Domain": userID_Domain,
            "token": token,
            "platform": "IOS"
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonParams)
            
            // Envia a requisição
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else { return }
            
            if (200...299).contains(httpResponse.statusCode) {
                 print("BRD_SERVER_SUCCESS: Token enviado com sucesso.")
            } else {
                let errorBody = String(data: data, encoding: .utf8) ?? "N/A"
                print("BRD_SERVER_ERROR: Code: \(httpResponse.statusCode), Erro: \(errorBody)")
            }
            
        } catch {
            print("BRD_SERVER_EXCEPTION: \(error.localizedDescription)")
        }
    }
}
