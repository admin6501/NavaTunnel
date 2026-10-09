import errno
import json
import os
import pty
import subprocess
import threading
import termios
from test_regressions import ScriptHarness

class MenuNavigationTests(ScriptHarness):
    def setUp(self):
        super().setUp()
        (self.state/'traffic.json').write_text(json.dumps({'counter':dict(interface='gre-t2',download=123,upload=45,limit=0,mode='both')}))

    def terminal(self,command,inputs,extra='',interactive=False):
        master,slave=pty.openpty()
        settings=termios.tcgetattr(slave)
        settings[3] &= ~termios.ECHO
        termios.tcsetattr(slave,termios.TCSANOW,settings)
        chunks=[]
        def read():
            while True:
                try:
                    chunk=os.read(master,65536)
                    if not chunk:break
                    chunks.append(chunk)
                except OSError as e:
                    if e.errno==errno.EIO:break
                    raise
        process=subprocess.Popen(['bash','-c','source "$1"\nsystemctl() { return 0; }; ip() { return 0; }; cli_traffic() { return 0; }; menu_import_existing() { return 0; };\n'+extra+'\n'+command,'navigation',str(self.library)],stdin=slave if interactive else subprocess.PIPE,stdout=slave,stderr=slave)
        os.close(slave)
        reader=threading.Thread(target=read);reader.start()
        try:
            if interactive:
                os.write(master,inputs.encode())
                process.wait(timeout=10)
            else:
                process.communicate(inputs.encode(),timeout=10)
        except Exception:
            process.kill();process.wait();raise
        finally:
            reader.join(timeout=3);os.close(master)
        self.assertEqual(process.returncode,0,b''.join(chunks).decode())
        return b''.join(chunks).decode().replace('\r','')

    def test_back_from_selected_tunnel_clears_parent_screen(self):
        out=self.terminal('menu_loop','1\n3\n2\n0\n0\n0\n')
        screens=out.split('\x1b[2J\x1b[H')
        self.assertGreaterEqual(len(screens),6)
        self.assertIn('Tunnel: same-name',out)
        parent=screens[-2]
        self.assertIn('1) Create tunnel on Iran',parent)
        self.assertNotIn('last use',parent)
        self.assertNotIn('Change service ports',parent)
        self.assertIn('Main menu',screens[-1])
        self.assertNotIn('Tunnel:',screens[-1])

    def test_global_iran_ip_is_not_on_selected_tunnel(self):
        out=self.terminal('menu_edit_peer','2\n0\n')
        self.assertNotIn('change IP Iran server',out)
        self.assertIn('13) Change FRP control port for this tunnel',out)
        self.assertIn('12) Set persistent MTU',out)
        entries=[line for line in out.split('\x1b[2J\x1b[H')[-1].splitlines() if line.startswith(('1)','2)','3)'))]
        self.assertEqual(entries[:3],['1) Start this tunnel','2) Stop this tunnel','3) Restart this tunnel'])
        parent=self.terminal('menu_tunnel','0\n')
        self.assertEqual(parent.count('6) Change Iran server IP'),1)

    def test_traffic_submenu_return_removes_traffic_actions(self):
        out=self.terminal('menu_edit_peer','2\n9\n0\n0\n')
        screens=out.split('\x1b[2J\x1b[H')
        self.assertIn('1) Refresh usage',out)
        self.assertIn('4) Change service ports',screens[-1])
        self.assertNotIn('1) Refresh usage',screens[-1])

    def test_loss_submenu_and_cancelled_protocol_return_cleanly(self):
        out=self.terminal('menu_edit_peer','2\n10\n0\n11\n0\n0\n')
        screens=out.split('\x1b[2J\x1b[H')
        self.assertIn('1) Enable loss recovery',out)
        self.assertIn('1) TCP (Default)',out)
        self.assertIn('4) Change service ports',screens[-1])
        self.assertNotIn('1) TCP (Default)',screens[-1])

    def test_invalid_tunnel_row_reprompts_without_selecting_another(self):
        result=self.run_shell("menu_select_peer <<<$'bad\\n99\\n000002'")
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout.strip(),'2')
        self.assertEqual(result.stderr.count('Invalid tunnel number'),2)

    def test_traffic_selector_reprompts_and_keeps_stdout_machine_readable(self):
        result=self.run_shell("menu_select_traffic <<<$'bad\\n9\\n1'")
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout.strip(),'counter')
        self.assertNotIn('\x1b',result.stdout)

    def test_foreign_back_returns_to_clean_tunnel_menu(self):
        self.peers=[];self.write_peers()
        (self.config/'frpc.toml').write_text('serverAddr="10.200.0.2"\nserverPort=7000\ntransport.protocol="tcp"\n')
        out=self.terminal('menu_tunnel','3\n0\n0\n')
        self.assertIn('Out server tunnel | FRPC',out)
        foreign_screen=next(s for s in out.split('\x1b[2J\x1b[H') if 'Out server tunnel | FRPC' in s)
        entries=[line for line in foreign_screen.splitlines() if line.startswith(('1)','2)','3)'))]
        self.assertEqual(entries[:3],['1) Start this tunnel','2) Stop this tunnel','3) Restart this tunnel'])
        last=out.split('\x1b[2J\x1b[H')[-1]
        self.assertIn('1) Create tunnel on Iran',last)
        self.assertNotIn('Out server tunnel | FRPC',last)

    def test_refresh_clears_previous_traffic_snapshot(self):
        out=self.terminal('menu_tunnel_traffic gre-t2','1\n0\n')
        screens=out.split('\x1b[2J\x1b[H')
        self.assertEqual(screens[-1].count('Traffic for this tunnel:'),1)
        self.assertEqual(screens[-1].count('1) Refresh usage'),1)

    def test_noninteractive_clear_does_not_emit_terminal_codes(self):
        result=self.run_shell('ui_clear; echo clean')
        self.assertEqual(result.stdout,'clean\n')
        self.assertEqual(result.stderr,'')

    def test_all_menu_exit_and_eof_paths_return_without_system_changes(self):
        # Read-only diagnostics and no-op helpers isolate navigation from live services.
        extra='''
cli_chaff() { :; }; cli_dpi_shield() { :; }; cli_perf() { :; }; cli_carrier() { :; };
init_watchdog_json() { :; }; doctor_health_check() { :; };
'''
        for menu in ('menu_loop','menu_tunnel','menu_optimization','menu_diagnostics_backup','menu_maintenance','menu_uninstall','menu_perf','menu_chaff','menu_dpi_shield','menu_carrier','menu_traffic','menu_foreign_tunnel','menu_watchdog'):
            for input_text in ('0\n',''):
                with self.subTest(menu=menu,input=input_text):
                    if menu=='menu_foreign_tunnel':
                        (self.config/'frpc.toml').write_text('serverAddr="10.200.0.2"\nserverPort=7000\n')
                    self.terminal(menu,input_text,extra)

    def test_main_sections_return_to_main_without_old_actions(self):
        out=self.terminal('menu_loop','2\n0\n3\n0\n4\n0\n5\n0\n6\n0\n0\n')
        last=out.split('\x1b[2J\x1b[H')[-1]
        self.assertIn('Main menu',last)
        for old in ('Backup schedule','Download and check executable files','Manual interface registration','Removal of tunnel components'):
            self.assertNotIn(old,last)

    def test_gre_submenu_is_its_own_screen(self):
        out=self.terminal('menu_edit_peer','2\n7\n0\n0\n')
        screen=next(s for s in out.split('\x1b[2J\x1b[H') if '1) GRE Direct' in s)
        self.assertNotIn('4) Change service ports',screen)
        self.assertNotIn('Download:',screen)

    def test_failed_edit_result_is_shown_before_next_redraw(self):
        out=self.terminal('menu_edit_peer','2\n6\ninvalid\n\n0\n',interactive=True)
        screens=out.split('\x1b[2J\x1b[H')
        error_screen=next(s for s in screens if 'Invalid peer public IP' in s)
        self.assertIn('New value:',error_screen)
        self.assertIn('Press Enter to return to the menu',error_screen)
        self.assertNotIn('Invalid peer public IP',screens[-1])
        self.assertIn('4) Change service ports',screens[-1])

    def test_connection_command_remains_on_interactive_screen_until_enter(self):
        self.peers[1].update(local_pub='203.0.113.1',local_gre='10.200.0.6',peer_gre='10.200.0.5',frp_port=7001,token='testingToken123')
        self.write_peers()
        out=self.terminal('menu_edit_peer','2\n8\n\n0\n',interactive=True)
        screens=out.split('\x1b[2J\x1b[H')
        code_screen=next(s for s in screens if 'NavaTunnel setup-foreign --bundle' in s)
        self.assertIn('Press Enter to return to the menu',code_screen)
        self.assertNotIn('NavaTunnel setup-foreign --bundle',screens[-1])

    def test_empty_tunnel_list_message_is_visible_before_parent_redraw(self):
        self.peers=[];self.write_peers()
        out=self.terminal('menu_tunnel','3\n\n0\n',interactive=True)
        screens=out.split('\x1b[2J\x1b[H')
        empty=next(s for s in screens if 'The tunnel is not listed' in s)
        self.assertIn('Press Enter to return to the menu',empty)
        self.assertNotIn('The tunnel is not listed',screens[-1])
