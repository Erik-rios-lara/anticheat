using System;
using System.IO;
using System.Security.Cryptography.X509Certificates;
using System.Runtime.InteropServices;

namespace L4D2AntiCheatScanner.Core
{
    public class SignatureInfo
    {
        public bool IsSigned { get; set; }
        public string Publisher { get; set; } = "Desconocido";
        public string StatusMessage { get; set; } = "";
    }

    public static class SignatureChecker
    {
        public static SignatureInfo CheckSignature(string filePath)
        {
            var info = new SignatureInfo();

            if (string.IsNullOrEmpty(filePath) || !File.Exists(filePath))
            {
                info.StatusMessage = "Archivo no encontrado";
                return info;
            }

            try
            {
                X509Certificate certificate = X509Certificate.CreateFromSignedFile(filePath);
                var cert2 = new X509Certificate2(certificate);

                info.IsSigned = true;
                info.Publisher = cert2.GetNameInfo(X509NameType.SimpleName, false) ?? cert2.Subject;
                info.StatusMessage = "Firmado";
            }
            catch (Exception ex)
            {
                info.IsSigned = false;
                info.Publisher = "No firmado / Firma inválida";
                info.StatusMessage = ex.Message;
            }

            return info;
        }
    }
}

