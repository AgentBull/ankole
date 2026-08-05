import { mountApp } from '../common/mount'
import { ConsoleApp, createConsoleRouter } from '../console/app'

mountApp(queryClient => <ConsoleApp router={createConsoleRouter(queryClient)} />)
