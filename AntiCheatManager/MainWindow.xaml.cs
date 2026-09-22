using System;
using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Media;

namespace AntiCheatManager
{
    public partial class MainWindow : Window
    {
        private AppManager appManager;

        public MainWindow()
        {
            InitializeComponent();
            DetectPath();
        }

        private void DetectPath()
        {
            string detected = SteamDetector.FindLeft4Dead2();
            if (!string.IsNullOrEmpty(detected))
            {
                TxtPath.Text = detected;
                appManager = new AppManager(detected);
                UpdateStatus();
            }
            else
            {
                TxtPath.Text = "No detectado. Por favor selecciona la carpeta manualmente.";
            }
        }

        private void BtnBrowse_Click(object sender, RoutedEventArgs e)
        {
            using (var dialog = new System.Windows.Forms.FolderBrowserDialog())
            {
                dialog.Description = "Selecciona la carpeta de instalación de Left 4 Dead 2";
                if (dialog.ShowDialog() == System.Windows.Forms.DialogResult.OK)
                {
                    TxtPath.Text = dialog.SelectedPath;
                    appManager = new AppManager(dialog.SelectedPath);
                    UpdateStatus();
                }
            }
        }

        private void UpdateStatus()
        {
            if (appManager == null || !appManager.IsGameFolderValid())
            {
                MessageBox.Show("La ruta seleccionada no parece contener 'left4dead2'.", "Ruta Inválida", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            bool hasMM = appManager.IsMetaModInstalled();
            bool hasSM = appManager.IsSourceModInstalled();
            bool hasAC = appManager.IsAntiCheatInstalled();
            bool isACEnabled = appManager.IsAntiCheatEnabled();

            LblMM.Text = hasMM ? "[✓] MetaMod:Source detectado" : "[✗] MetaMod:Source no detectado";
            LblMM.Foreground = hasMM ? Brushes.LightGreen : Brushes.OrangeRed;

            LblSM.Text = hasSM ? "[✓] SourceMod detectado" : "[✗] SourceMod no detectado";
            LblSM.Foreground = hasSM ? Brushes.LightGreen : Brushes.OrangeRed;

            if (hasAC)
            {
                LblAC.Text = isACEnabled ? "[✓] ANTI-CHEAT: ACTIVADO" : "[✓] ANTI-CHEAT: DESACTIVADO";
                LblAC.Foreground = isACEnabled ? Brushes.LightGreen : Brushes.Orange;
                BtnToggle.Content = isACEnabled ? "DESACTIVAR ANTI-CHEAT" : "ACTIVAR ANTI-CHEAT";
                BtnToggle.Background = isACEnabled ? new SolidColorBrush(Color.FromRgb(204, 51, 51)) : new SolidColorBrush(Color.FromRgb(76, 175, 80));
            }
            else
            {
                LblAC.Text = "[✗] ANTI-CHEAT: NO INSTALADO";
                LblAC.Foreground = Brushes.OrangeRed;
                BtnToggle.Content = "ACTIVAR ANTI-CHEAT";
                BtnToggle.Background = Brushes.Gray;
            }

            bool serverRunning = appManager.IsServerRunning();
            LblServer.Text = serverRunning ? "Servidor detectado: EJECUTÁNDOSE" : "Servidor detectado: DETENIDO";
            LblServer.Foreground = serverRunning ? Brushes.LightGreen : Brushes.DarkGray;
        }

        private void BtnInstall_Click(object sender, RoutedEventArgs e)
        {
            if (appManager == null || !appManager.IsGameFolderValid())
            {
                MessageBox.Show("Selecciona una ruta válida de L4D2 primero.", "Error", MessageBoxButton.OK, MessageBoxImage.Error);
                return;
            }

            appManager.BackupFile("addons\\sourcemod\\configs\\admins_simple.ini");
            appManager.BackupFile("cfg\\sourcemod\\anticheat.cfg");

            var result = InstallerService.Install(appManager.GamePath, AppDomain.CurrentDomain.BaseDirectory);
            if (result.success)
            {
                MessageBox.Show(result.message, "Éxito", MessageBoxButton.OK, MessageBoxImage.Information);
                UpdateStatus();
            }
            else
            {
                MessageBox.Show(result.message, "Error en instalación", MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }

        private void BtnToggle_Click(object sender, RoutedEventArgs e)
        {
            if (appManager == null || !appManager.IsAntiCheatInstalled())
            {
                MessageBox.Show("El Anti-Cheat no está instalado.", "Error", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            appManager.ToggleAntiCheat();
            UpdateStatus();
            MessageBox.Show("Estado cambiado.\nRecuerda: El cambio en disco no necesariamente significa que SourceMod ya haya cargado/descargado el plugin si el servidor ya está corriendo (requiere cambiar de mapa o recargar sm).", "Aviso", MessageBoxButton.OK, MessageBoxImage.Information);
        }

        private void BtnCheckMMSM_Click(object sender, RoutedEventArgs e)
        {
            UpdateStatus();
            MessageBox.Show("Se ha vuelto a escanear la carpeta en busca de MetaMod y SourceMod.", "Escaneo Completo", MessageBoxButton.OK, MessageBoxImage.Information);
        }

        private void BtnVerify_Click(object sender, RoutedEventArgs e)
        {
            UpdateStatus();
            MessageBox.Show("Verificación completada.", "Verificar", MessageBoxButton.OK, MessageBoxImage.Information);
        }

        private void BtnLogs_Click(object sender, RoutedEventArgs e)
        {
            if (appManager == null) return;
            string logPath = Path.Combine(appManager.GamePath, "left4dead2", "logs", "anticheat");
            if (Directory.Exists(logPath))
            {
                Process.Start("explorer.exe", logPath);
            }
            else
            {
                MessageBox.Show("Aún no existen logs del Anti-Cheat en la carpeta.", "Logs", MessageBoxButton.OK, MessageBoxImage.Information);
            }
        }

        private void BtnHelpSM_Click(object sender, RoutedEventArgs e)
        {
            Process.Start(new ProcessStartInfo("https://wiki.alliedmods.net/Installing_SourceMod") { UseShellExecute = true });
        }
    }
}