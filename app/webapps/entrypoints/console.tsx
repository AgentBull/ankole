import { mountApp } from '../common/mount'
import { ConsoleApp, createConsoleRouter } from '../console/app'

void mountApp(queryClient => <ConsoleApp router={createConsoleRouter(queryClient)} />)
